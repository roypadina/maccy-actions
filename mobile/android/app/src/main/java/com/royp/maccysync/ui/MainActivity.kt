package com.royp.maccysync.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.rememberCoroutineScope
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.clipboard.ClipboardAccessibilityService
import com.royp.maccysync.clipboard.ClipboardWriter
import com.royp.maccysync.data.ClipEntity
import com.royp.maccysync.net.SyncForegroundService
import com.royp.maccysync.pairing.PairingActivity
import com.royp.maccysync.sync.SyncController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    requestNotificationPermission()
    val app = application as MaccyApp
    // Start the sync service from this foreground context (allowed on Android 12+,
    // unlike Application.onCreate).
    if (app.prefs.syncEnabled && app.prefs.isPaired) {
      SyncForegroundService.start(this)
    }
    setContent {
      val scheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
      MaterialTheme(colorScheme = scheme) { App(app) }
    }
  }

  private fun requestNotificationPermission() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
      checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    ) {
      requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
    }
  }
}

@Composable
private fun App(app: MaccyApp) {
  var tab by remember { mutableIntStateOf(0) }
  Scaffold(
    bottomBar = {
      NavigationBar {
        NavigationBarItem(
          selected = tab == 0, onClick = { tab = 0 },
          icon = { Icon(Icons.Filled.Home, null) }, label = { Text("Clips") })
        NavigationBarItem(
          selected = tab == 1, onClick = { tab = 1 },
          icon = { Icon(Icons.Filled.Settings, null) }, label = { Text("Settings") })
      }
    }
  ) { padding ->
    Column(Modifier.fillMaxSize().padding(padding)) {
      when (tab) {
        0 -> HomeScreen(app)
        else -> SettingsScreen(app)
      }
    }
  }
}

@Composable
private fun HomeScreen(app: MaccyApp) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  val state by app.controller.state.collectAsStateWithLifecycle()
  val peerName by app.controller.peerName.collectAsStateWithLifecycle()
  val macClips by app.repo.macClips().collectAsStateWithLifecycle(initialValue = emptyList())
  val localClips by app.repo.localClips().collectAsStateWithLifecycle(initialValue = emptyList())

  fun toast(message: String) = Toast.makeText(context, message, Toast.LENGTH_SHORT).show()

  LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
    item {
      Text(
        "Status: ${statusLabel(state)}" + if (peerName.isNotEmpty()) " · $peerName" else "",
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.padding(vertical = 10.dp)
      )
    }
    item { SectionHeader(if (peerName.isEmpty()) "From Mac" else "From $peerName") }
    if (macClips.isEmpty()) item { Empty("No clips from your Mac yet") }
    items(macClips) { clip ->
      ClipRow(clip) {
        scope.launch {
          val ok = withContext(Dispatchers.IO) { app.controller.applyMacClip(clip.toMeta()) }
          toast(if (ok) "Copied to clipboard" else "Couldn't fetch content")
        }
      }
    }
    item { SectionHeader("This phone") }
    if (localClips.isEmpty()) item { Empty("Copies on this phone appear here") }
    items(localClips) { clip ->
      ClipRow(clip) {
        clip.text?.let { ClipboardWriter.setText(context, it); toast("Copied") }
      }
    }
  }
}

@Composable
private fun SettingsScreen(app: MaccyApp) {
  val context = LocalContext.current
  var syncEnabled by remember { mutableStateOf(app.prefs.syncEnabled) }
  var sendText by remember { mutableStateOf(app.prefs.sendText) }
  var deviceName by remember { mutableStateOf(app.prefs.deviceName) }
  var paired by remember { mutableStateOf(app.prefs.isPaired) }
  val a11yEnabled = isAccessibilityEnabled(context)

  Column(
    Modifier.fillMaxSize().padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(14.dp)
  ) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Enable sync", style = MaterialTheme.typography.titleMedium)
      Switch(checked = syncEnabled, onCheckedChange = {
        syncEnabled = it
        app.prefs.syncEnabled = it
        if (it) SyncForegroundService.start(context) else SyncForegroundService.stop(context)
      })
    }

    OutlinedTextField(
      value = deviceName, onValueChange = { deviceName = it; app.prefs.deviceName = it },
      label = { Text("This phone's name") }, modifier = Modifier.fillMaxWidth()
    )

    Card(Modifier.fillMaxWidth()) {
      Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Auto-capture", style = MaterialTheme.typography.titleMedium)
        Text(
          if (a11yEnabled) "Accessibility access granted — copies are captured automatically."
          else "Grant Accessibility access so copies are captured automatically.",
          style = MaterialTheme.typography.bodySmall
        )
        OutlinedButton(onClick = {
          context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }) { Text(if (a11yEnabled) "Accessibility settings" else "Grant access") }
      }
    }

    Card(Modifier.fillMaxWidth()) {
      Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Pairing", style = MaterialTheme.typography.titleMedium)
        if (paired) {
          Text("Paired with ${app.prefs.macName ?: "Mac"}", style = MaterialTheme.typography.bodyMedium)
          Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { context.startActivity(Intent(context, PairingActivity::class.java)) }) {
              Text("Re-pair")
            }
            Button(onClick = {
              app.controller.unpair()
              SyncForegroundService.stop(context)
              paired = false
            }) { Text("Unpair") }
          }
        } else {
          Text("Scan the QR code shown in Maccy on your Mac.", style = MaterialTheme.typography.bodySmall)
          Button(onClick = { context.startActivity(Intent(context, PairingActivity::class.java)) }) {
            Text("Pair with Mac")
          }
        }
      }
    }

    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Send my copies to Mac", style = MaterialTheme.typography.bodyLarge)
      Switch(checked = sendText, onCheckedChange = { sendText = it; app.prefs.sendText = it })
    }
  }
}

@Composable
private fun SectionHeader(title: String) {
  Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
}

@Composable
private fun Empty(message: String) {
  Text(message, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 8.dp))
}

@Composable
private fun ClipRow(clip: ClipEntity, onClick: () -> Unit) {
  Card(Modifier.fillMaxWidth().padding(vertical = 3.dp).clickable { onClick() }) {
    Column(Modifier.padding(10.dp)) {
      Text(
        clip.preview.ifEmpty { clip.filename ?: "Untitled" },
        maxLines = 2, overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.bodyMedium
      )
      Text(kindLabel(clip), style = MaterialTheme.typography.labelSmall)
    }
  }
}

private fun statusLabel(state: SyncController.ConnState): String = when (state) {
  SyncController.ConnState.Connected -> "Connected"
  SyncController.ConnState.Connecting -> "Connecting…"
  SyncController.ConnState.Pairing -> "Pairing…"
  SyncController.ConnState.Disconnected -> "Disconnected"
}

private fun kindLabel(clip: ClipEntity): String = when (clip.kind) {
  "image" -> "Image"
  "file" -> "File · ${clip.filename ?: ""}"
  else -> "Text"
}

private fun isAccessibilityEnabled(context: Context): Boolean {
  val expected = ComponentName(context, ClipboardAccessibilityService::class.java).flattenToString()
  val enabled = Settings.Secure.getString(
    context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
  ) ?: return false
  return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
}
