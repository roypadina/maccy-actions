package com.royp.maccysync.core

import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Cross-language golden vectors. The same expected hex values are asserted in the
// Mac suite (MaccyTests/SyncTests.swift, testInteropGoldenVectors) — if both sides
// match these, the Kotlin (BouncyCastle) and Swift (CryptoKit) crypto interoperate
// byte-for-byte. Inputs are fixed; see that file for the mirrored Swift test.
class InteropVectorGen {
  private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

  @Test fun matchesGoldenVectors() {
    val edSeed = ByteArray(32) { it.toByte() }
    val msg = "MaccySync-interop".toByteArray()
    val xClient = ByteArray(32) { 0x11 }
    val xServer = ByteArray(32) { 0x22 }
    val aeadKey = ByteArray(32) { 0x33 }
    val aeadPt = "interop-test".toByteArray()

    val id = Identity.fromSeed(edSeed)
    val clientPriv = X25519PrivateKeyParameters(xClient, 0)
    val serverPriv = X25519PrivateKeyParameters(xServer, 0)
    val clientPub = clientPriv.generatePublicKey().encoded
    val serverPub = serverPriv.generatePublicKey().encoded
    val shared = Handshake.sharedSecret(clientPriv, serverPub)
    val (c2s, s2c) = Handshake.deriveKeys(shared, clientPub, serverPub)
    val aead = SessionCipher(aeadKey, aeadKey, isServer = false).seal(aeadPt)

    assertEquals("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8", id.publicKeyRaw.hex())
    assertTrue(Identity.verify(id.sign(msg), msg, id.publicKeyRaw))
    assertEquals("7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13", clientPub.hex())
    assertEquals("0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20", serverPub.hex())
    assertEquals("9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056", shared.hex())
    assertEquals("1df9915fb61c766ab5558bb1e7843c1b9993a398011ba8d255e8486c5e97cefa", c2s.hex())
    assertEquals("646e7e4458201270bc0f0650ec6408addc1b217fdc22438f81ed778124b137e9", s2c.hex())
    assertEquals("bea2fd2f2bd685616164663676455d54a6ed510c77d80c5db9928c06", aead.hex())
  }
}
