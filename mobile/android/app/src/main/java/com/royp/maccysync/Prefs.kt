package com.royp.maccysync

import android.content.Context
import android.os.Build
import com.royp.maccysync.core.Identity
import com.royp.maccysync.core.b64
import com.royp.maccysync.core.fromB64
import java.util.UUID

// Local persisted settings: this device's identity + the paired Mac + toggles.
class Prefs(context: Context) {
  private val sp = context.getSharedPreferences("maccy_sync", Context.MODE_PRIVATE)

  fun identity(): Identity {
    val seed = sp.getString("identity_seed", null)
    if (seed != null) return Identity.fromSeed(seed.fromB64())
    val created = Identity.generate()
    sp.edit().putString("identity_seed", created.seed.b64()).apply()
    return created
  }

  var deviceId: String
    get() {
      val existing = sp.getString("device_id", null)
      if (existing != null) return existing
      val generated = UUID.randomUUID().toString()
      sp.edit().putString("device_id", generated).apply()
      return generated
    }
    set(value) { sp.edit().putString("device_id", value).apply() }

  var deviceName: String
    get() = sp.getString("device_name", null) ?: (Build.MODEL ?: "My Phone")
    set(value) { sp.edit().putString("device_name", value).apply() }

  var syncEnabled: Boolean
    get() = sp.getBoolean("sync_enabled", true)
    set(value) { sp.edit().putBoolean("sync_enabled", value).apply() }

  var sendText: Boolean
    get() = sp.getBoolean("send_text", true)
    set(value) { sp.edit().putBoolean("send_text", value).apply() }

  // --- Paired Mac ---

  val isPaired: Boolean get() = sp.getString("mac_idpub", null) != null

  var macIdPub: String?
    get() = sp.getString("mac_idpub", null)
    set(value) { sp.edit().putString("mac_idpub", value).apply() }

  var macName: String?
    get() = sp.getString("mac_name", null)
    set(value) { sp.edit().putString("mac_name", value).apply() }

  var macHost: String?
    get() = sp.getString("mac_host", null)
    set(value) { sp.edit().putString("mac_host", value).apply() }

  var macPort: Int
    get() = sp.getInt("mac_port", 53121)
    set(value) { sp.edit().putInt("mac_port", value).apply() }

  var macDeviceId: String?
    get() = sp.getString("mac_device_id", null)
    set(value) { sp.edit().putString("mac_device_id", value).apply() }

  fun savePaired(idPub: String, name: String, host: String, port: Int, deviceId: String) {
    sp.edit()
      .putString("mac_idpub", idPub)
      .putString("mac_name", name)
      .putString("mac_host", host)
      .putInt("mac_port", port)
      .putString("mac_device_id", deviceId)
      .apply()
  }

  fun clearPaired() {
    sp.edit()
      .remove("mac_idpub").remove("mac_name").remove("mac_host")
      .remove("mac_port").remove("mac_device_id")
      .apply()
  }
}
