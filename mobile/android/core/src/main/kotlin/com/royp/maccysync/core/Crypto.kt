package com.royp.maccysync.core

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64

fun ByteArray.b64(): String = Base64.getEncoder().encodeToString(this)
fun String.fromB64(): ByteArray = Base64.getDecoder().decode(this)

// Long-lived Ed25519 identity. Persistence (the 32-byte seed) is the app's job.
class Identity private constructor(private val priv: Ed25519PrivateKeyParameters) {
  val publicKeyRaw: ByteArray = priv.generatePublicKey().encoded
  val pin: String get() = publicKeyRaw.b64()
  val seed: ByteArray get() = priv.encoded

  fun sign(message: ByteArray): ByteArray {
    val signer = Ed25519Signer()
    signer.init(true, priv)
    signer.update(message, 0, message.size)
    return signer.generateSignature()
  }

  companion object {
    fun generate(): Identity = Identity(Ed25519PrivateKeyParameters(SecureRandom()))
    fun fromSeed(seed: ByteArray): Identity = Identity(Ed25519PrivateKeyParameters(seed, 0))

    fun verify(signature: ByteArray, message: ByteArray, publicKeyRaw: ByteArray): Boolean =
      runCatching {
        val signer = Ed25519Signer()
        signer.init(false, Ed25519PublicKeyParameters(publicKeyRaw, 0))
        signer.update(message, 0, message.size)
        signer.verifySignature(signature)
      }.getOrDefault(false)
  }
}

object Handshake {
  fun newEphemeral(): X25519PrivateKeyParameters = X25519PrivateKeyParameters(SecureRandom())

  fun publicBytes(priv: X25519PrivateKeyParameters): ByteArray = priv.generatePublicKey().encoded

  fun transcript(clientEph: ByteArray, serverEph: ByteArray): ByteArray = clientEph + serverEph

  fun sharedSecret(localPriv: X25519PrivateKeyParameters, peerPub: ByteArray): ByteArray {
    val agreement = X25519Agreement()
    agreement.init(localPriv)
    val out = ByteArray(agreement.agreementSize)
    agreement.calculateAgreement(X25519PublicKeyParameters(peerPub, 0), out, 0)
    return out
  }

  fun deriveKeys(shared: ByteArray, clientEph: ByteArray, serverEph: ByteArray): Pair<ByteArray, ByteArray> {
    val salt = clientEph + serverEph
    return hkdf(shared, salt, "MaccySync-v1-c2s") to hkdf(shared, salt, "MaccySync-v1-s2c")
  }

  private fun hkdf(ikm: ByteArray, salt: ByteArray, info: String): ByteArray {
    val generator = HKDFBytesGenerator(SHA256Digest())
    generator.init(HKDFParameters(ikm, salt, info.toByteArray(Charsets.UTF_8)))
    val out = ByteArray(32)
    generator.generateBytes(out, 0, 32)
    return out
  }
}

// ChaCha20-Poly1305 with an implicit per-direction counter nonce (4 zero bytes +
// 8-byte big-endian counter), matching the Mac SessionCipher.
class SessionCipher(c2s: ByteArray, s2c: ByteArray, isServer: Boolean) {
  private val sendKey = if (isServer) s2c else c2s
  private val recvKey = if (isServer) c2s else s2c
  private var sendCounter = 0L
  private var recvCounter = 0L

  fun seal(plaintext: ByteArray): ByteArray = aead(true, sendKey, nonce(sendCounter++), plaintext)

  fun open(data: ByteArray): ByteArray {
    val plaintext = aead(false, recvKey, nonce(recvCounter), data)
    recvCounter++
    return plaintext
  }

  private fun nonce(counter: Long): ByteArray {
    val buffer = ByteBuffer.allocate(12)
    buffer.position(4)
    buffer.putLong(counter)
    return buffer.array()
  }

  private fun aead(forEncryption: Boolean, key: ByteArray, nonce: ByteArray, input: ByteArray): ByteArray {
    val cipher = ChaCha20Poly1305()
    cipher.init(forEncryption, AEADParameters(KeyParameter(key), 128, nonce))
    val out = ByteArray(cipher.getOutputSize(input.size))
    val len = cipher.processBytes(input, 0, input.size, out, 0)
    cipher.doFinal(out, len)
    return out
  }
}
