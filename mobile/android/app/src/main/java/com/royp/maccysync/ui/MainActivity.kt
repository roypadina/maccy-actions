package com.royp.maccysync.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Notes
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.TextButton
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.clipboard.ClipboardAccessibilityService
import com.royp.maccysync.clipboard.ClipboardCapture
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
    if (app.prefs.syncEnabled && app.prefs.isPaired) SyncForegroundService.start(this)
    requestBatteryExemptionIfNeeded()
    setContent { MaccyTheme { App(app) } }
  }

  // Reading the clipboard is only permitted while we're the focused app. Every
  // time the app comes forward, grab the current clip so the phone list mirrors
  // the system clipboard 1:1 (the only no-root way to auto-capture on Android 10+).
  override fun onResume() {
    super.onResume()
    val app = application as MaccyApp
    // Revive a connection Samsung may have frozen in the background + pull latest.
    app.controller.nudge()
    // Always surface the current clipboard value in the This Phone list on open.
    ClipboardCapture.currentText(this)?.let { app.controller.captureForList(it) }
  }

  private fun requestNotificationPermission() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
      checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    ) {
      requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
    }
  }

  @SuppressLint("BatteryLife")
  private fun requestBatteryExemptionIfNeeded() {
    val prefs = (application as MaccyApp).prefs
    if (prefs.batteryAsked) return
    val pm = getSystemService(PowerManager::class.java) ?: return
    if (!pm.isIgnoringBatteryOptimizations(packageName)) {
      prefs.batteryAsked = true
      runCatching {
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
      }
    }
  }
}

@Composable
private fun App(app: MaccyApp) {
  var onSettings by remember { mutableStateOf(false) }
  val context = LocalContext.current
  Box(Modifier.fillMaxSize().background(Hue.bgGradient)) {
    if (onSettings) SettingsScreen(app) else ClipsScreen(app)
    BottomBar(
      onSettings = onSettings,
      onHome = { onSettings = false },
      onOpenSettings = { onSettings = true },
      modifier = Modifier.align(Alignment.BottomCenter)
    )
  }
}

// MARK: clips

@Composable
private fun ClipsScreen(app: MaccyApp) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var tab by remember { mutableIntStateOf(0) }
  val state by app.controller.state.collectAsStateWithLifecycle()
  val peerName by app.controller.peerName.collectAsStateWithLifecycle()
  val phoneClips by app.repo.localClips().collectAsStateWithLifecycle(initialValue = emptyList())
  val macClips by app.repo.macClips().collectAsStateWithLifecycle(initialValue = emptyList())
  fun toast(m: String) = Toast.makeText(context, m, Toast.LENGTH_SHORT).show()

  // SAF picker → import the file into "This Phone" as a file clip (no auto-upload;
  // the user taps the clip's ↑ to send).
  val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
    uri?.let { app.controller.importFile(it) { ok -> toast(if (ok) "Added — tap ↑ to send" else "Couldn't add file") } }
  }

  // Live transfer indicator (both directions).
  val transfer by app.controller.transfer.collectAsStateWithLifecycle(initialValue = null)
  // Mac→phone download: choose where to save, then stream + offer to open.
  var pendingDownload by remember { mutableStateOf<ClipEntity?>(null) }
  var savedFile by remember { mutableStateOf<Pair<Uri, String>?>(null) }  // (uri, mime) for "Open"
  val saveFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
    val clip = pendingDownload; pendingDownload = null
    if (uri != null && clip != null) {
      app.controller.downloadToUri(clip.toMeta(), uri) { ok ->
        if (ok) savedFile = uri to (clip.mime ?: "*/*") else toast("Download failed — keep the phone open")
      }
    }
  }

  transfer?.let { TransferSheet(it) }
  savedFile?.let { (uri, mime) ->
    OpenSavedDialog(
      onOpen = {
        runCatching {
          context.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
              .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
          )
        }.onFailure { toast("No app to open this file") }
        savedFile = null
      },
      onDismiss = { savedFile = null }
    )
  }

  Column(Modifier.fillMaxSize().statusBarsPadding()) {
    Hero(state, peerName, app.prefs.isPaired, app.prefs.macName, phoneClips.size, macClips.size)

    Column(
      Modifier
        .fillMaxSize()
        .padding(top = 18.dp)
        .clip(RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp))
        .background(Hue.surface)
    ) {
      PillTabs(tab) { tab = it }
      val phone = tab == 0
      val items = if (phone) phoneClips else macClips
      val tile = if (phone) Hue.phoneTile() else Hue.macTile()
      if (phone) AttachFileButton { pickFile.launch("*/*") }
      if (items.isEmpty()) {
        if (phone) EmptyState("Nothing here yet", "Attach a file, share text here, or copy on this phone.")
        else EmptyState("No Mac clips", "Copy on the Mac — it lands here.")
      } else LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 6.dp, bottom = 120.dp)
      ) {
        items(items, key = { it.id }) { clip ->
          val isFile = clip.kind == "file"
          if (phone) {
            // Upload to Mac (works for text and file clips).
            val upload: () -> Unit = {
              app.controller.sendToMac(clip.toMeta()) { ok -> toast(if (ok) "Sent to Mac" else "Not connected") }
            }
            ClipRow(
              clip, tile, trailing = Icons.Rounded.CloudUpload,
              onRow = {
                if (isFile) upload()
                else clip.text?.let { ClipboardWriter.setText(context, it); toast("Copied") }
              },
              onTrailing = upload
            )
          } else {
            // File → pick a save location (then stream + offer Open); text/image → clipboard/Pictures.
            val download: () -> Unit = {
              if (isFile) {
                pendingDownload = clip
                saveFile.launch(clip.filename ?: "file")
              } else {
                scope.launch {
                  val ok = withContext(Dispatchers.IO) { app.controller.applyMacClip(clip.toMeta()) }
                  toast(if (ok) "Copied to clipboard" else "Couldn't fetch — connect the phone")
                }
              }
            }
            ClipRow(
              clip, tile,
              trailing = if (isFile) Icons.Rounded.CloudDownload else Icons.Rounded.ContentCopy,
              onRow = download, onTrailing = download
            )
          }
        }
      }
    }
  }
}

@Composable
private fun Hero(
  state: SyncController.ConnState, peerName: String, paired: Boolean,
  macName: String?, phoneCount: Int, macCount: Int
) {
  Box(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = 16.dp, vertical = 14.dp)
      .shadow(22.dp, RoundedCornerShape(30.dp), spotColor = Hue.purple, ambientColor = Hue.blue)
      .clip(RoundedCornerShape(30.dp))
      .background(Hue.heroGradient)
      .padding(22.dp)
  ) {
    Column {
      Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(26.dp).clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
          Icon(Icons.Rounded.Bolt, null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(9.dp))
        Text("Maccy Sync", color = Color.White, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.weight(1f))
        StatusPill(state, peerName)
      }
      Spacer(Modifier.height(22.dp))
      Text(if (paired) "PAIRED DEVICE" else "GET STARTED", color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.labelSmall)
      Spacer(Modifier.height(5.dp))
      Text(
        if (paired) (macName ?: "Your Mac") else "Not paired yet",
        color = Color.White, style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis
      )
      Spacer(Modifier.height(18.dp))
      Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        HeroStat("On this phone", phoneCount, Modifier.weight(1f))
        HeroStat("From Mac", macCount, Modifier.weight(1f))
      }
    }
  }
}

@Composable
private fun HeroStat(label: String, count: Int, modifier: Modifier = Modifier) {
  Column(
    modifier.clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.12f)).padding(14.dp)
  ) {
    Text(count.toString(), color = Color.White, style = MaterialTheme.typography.titleLarge)
    Text(label, color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall)
  }
}

@Composable
private fun StatusPill(state: SyncController.ConnState, peerName: String) {
  val (label, color) = when (state) {
    SyncController.ConnState.Connected -> "LIVE" to Color(0xFF7DE39B)
    SyncController.ConnState.Connecting -> "SYNC" to Color(0xFFF3D27A)
    SyncController.ConnState.Pairing -> "PAIR" to Color(0xFFF3D27A)
    SyncController.ConnState.Disconnected -> "OFFLINE" to Color.White.copy(alpha = 0.7f)
  }
  val live = state == SyncController.ConnState.Connected || state == SyncController.ConnState.Connecting
  Row(
    Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.16f)).padding(horizontal = 10.dp, vertical = 5.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PulseDot(color, live)
    Spacer(Modifier.width(6.dp))
    Text(label, color = Color.White, style = MaterialTheme.typography.labelSmall)
  }
}

@Composable
private fun PulseDot(color: Color, pulsing: Boolean) {
  val a = if (pulsing) {
    rememberInfiniteTransition(label = "p").animateFloat(
      0.35f, 1f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "d"
    ).value
  } else 1f
  Box(Modifier.size(7.dp).clip(CircleShape).background(color.copy(alpha = a)))
}

@Composable
private fun PillTabs(selected: Int, onSelect: (Int) -> Unit) {
  Row(
    Modifier.fillMaxWidth().padding(16.dp).clip(RoundedCornerShape(14.dp)).background(Hue.surfaceHi).padding(5.dp)
  ) {
    Segment("This Phone", selected == 0, Hue.phoneTile(), Modifier.weight(1f)) { onSelect(0) }
    Segment("From Mac", selected == 1, Hue.macTile(), Modifier.weight(1f)) { onSelect(1) }
  }
}

@Composable
private fun Segment(label: String, active: Boolean, activeBrush: Brush, modifier: Modifier, onClick: () -> Unit) {
  val fg by animateColorAsState(if (active) Color.White else Hue.muted, label = "fg")
  Box(
    modifier
      .clip(RoundedCornerShape(10.dp))
      .then(if (active) Modifier.background(activeBrush) else Modifier)
      .clickable { onClick() }
      .padding(vertical = 11.dp),
    contentAlignment = Alignment.Center
  ) { Text(label, color = fg, style = MaterialTheme.typography.labelLarge) }
}

@Composable
private fun AttachFileButton(onClick: () -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = 14.dp, vertical = 4.dp)
      .clip(RoundedCornerShape(14.dp))
      .border(1.dp, Hue.border, RoundedCornerShape(14.dp))
      .background(Hue.surfaceHi)
      .clickable { onClick() }
      .padding(vertical = 12.dp),
    horizontalArrangement = Arrangement.Center,
    verticalAlignment = Alignment.CenterVertically
  ) {
    Icon(Icons.Rounded.Add, null, tint = Hue.text, modifier = Modifier.size(18.dp))
    Spacer(Modifier.width(8.dp))
    Text("Attach a file", color = Hue.text, style = MaterialTheme.typography.labelLarge)
  }
}

@Composable
private fun TransferSheet(t: SyncController.Transfer) {
  val ctx = LocalContext.current
  val pct = if (t.total > 0) (t.done.toFloat() / t.total).coerceIn(0f, 1f) else 0f
  fun human(b: Long) = android.text.format.Formatter.formatShortFileSize(ctx, b)
  AlertDialog(
    onDismissRequest = {},
    confirmButton = {},
    title = { Text(if (t.incoming) "Receiving from Mac" else "Sending to Mac") },
    text = {
      Column {
        Text(t.name, color = Hue.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(14.dp))
        LinearProgressIndicator(progress = { pct }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        Text("${(pct * 100).toInt()}%  ·  ${human(t.done)} / ${human(t.total)}",
          color = Hue.muted, style = MaterialTheme.typography.bodySmall)
      }
    }
  )
}

@Composable
private fun OpenSavedDialog(onOpen: () -> Unit, onDismiss: () -> Unit) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("Saved") },
    text = { Text("File downloaded from your Mac.") },
    confirmButton = { TextButton(onClick = onOpen) { Text("Open") } },
    dismissButton = { TextButton(onClick = onDismiss) { Text("Done") } }
  )
}

@Composable
private fun ClipRow(clip: ClipEntity, tile: Brush, trailing: ImageVector, onRow: () -> Unit, onTrailing: () -> Unit) {
  Row(
    Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable { onRow() }.padding(vertical = 9.dp, horizontal = 8.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(Modifier.size(46.dp).clip(RoundedCornerShape(14.dp)).background(tile), contentAlignment = Alignment.Center) {
      Icon(kindIcon(clip.kind), null, tint = Color.White, modifier = Modifier.size(20.dp))
    }
    Column(Modifier.weight(1f).padding(horizontal = 13.dp)) {
      Text(clip.preview.ifBlank { clip.filename ?: "Untitled" }, color = Hue.text, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
      Spacer(Modifier.height(3.dp))
      Text(subtitle(clip), color = Hue.muted, style = MaterialTheme.typography.bodySmall)
      if (clip.kind == "file" && !clip.path.isNullOrBlank()) {
        Spacer(Modifier.height(2.dp))
        Text(clip.path, color = Hue.faint, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
      }
    }
    Box(
      Modifier.size(38.dp).clip(CircleShape).background(Hue.surfaceHi).clickable { onTrailing() },
      contentAlignment = Alignment.Center
    ) {
      Icon(trailing, "action", tint = Hue.muted, modifier = Modifier.size(17.dp))
    }
  }
}

@Composable
private fun EmptyState(title: String, subtitle: String) {
  Column(Modifier.fillMaxSize().padding(32.dp).padding(bottom = 80.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
    Box(Modifier.size(64.dp).clip(RoundedCornerShape(20.dp)).background(Hue.surfaceHi), contentAlignment = Alignment.Center) {
      Icon(Icons.Rounded.ContentCopy, null, tint = Hue.faint, modifier = Modifier.size(28.dp))
    }
    Spacer(Modifier.height(16.dp))
    Text(title, color = Hue.text, style = MaterialTheme.typography.titleMedium)
    Spacer(Modifier.height(6.dp))
    Text(subtitle, color = Hue.muted, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
  }
}

// MARK: settings

@Composable
private fun SettingsScreen(app: MaccyApp) {
  val context = LocalContext.current
  var syncEnabled by remember { mutableStateOf(app.prefs.syncEnabled) }
  var deviceName by remember { mutableStateOf(app.prefs.deviceName) }
  var paired by remember { mutableStateOf(app.prefs.isPaired) }
  val a11y = isAccessibilityEnabled(context)
  val exempt = isBatteryExempt(context)

  LazyColumn(
    Modifier.fillMaxSize().statusBarsPadding(),
    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 120.dp),
    verticalArrangement = Arrangement.spacedBy(14.dp)
  ) {
    item { Text("Settings", color = Hue.text, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)) }
    item {
      Card("SYNC") {
        ToggleRow("Enable clipboard sync", syncEnabled) {
          syncEnabled = it; app.prefs.syncEnabled = it
          if (it) SyncForegroundService.start(context) else SyncForegroundService.stop(context)
        }
        FieldRow("This phone's name", deviceName) { deviceName = it; app.prefs.deviceName = it }
      }
    }
    item {
      Card("PAIRING") {
        if (paired) {
          Text("Paired with ${app.prefs.macName ?: "Mac"}", color = Hue.text, style = MaterialTheme.typography.bodyLarge)
          Spacer(Modifier.height(12.dp))
          Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Ghost("Re-pair") { context.startActivity(Intent(context, PairingActivity::class.java)) }
            Ghost("Unpair", Hue.coral) { app.controller.unpair(); SyncForegroundService.stop(context); paired = false }
          }
        } else {
          Text("Scan the QR shown in Maccy on your Mac.", color = Hue.muted, style = MaterialTheme.typography.bodyMedium)
          Spacer(Modifier.height(12.dp))
          Primary("Pair with Mac") { context.startActivity(Intent(context, PairingActivity::class.java)) }
        }
      }
    }
    item {
      Card("KEEP RUNNING") {
        StatusLine(exempt, if (exempt) "Battery unrestricted — stays connected." else "Samsung suspends it in the background.")
        if (!exempt) { Spacer(Modifier.height(12.dp)); Ghost("Allow unrestricted") {
          runCatching { context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))) }
        } }
      }
    }
    item {
      Card("AUTO-CAPTURE") {
        StatusLine(a11y, if (a11y) "Accessibility on (where the OS allows)." else "Optional — some devices block background reads.")
        Spacer(Modifier.height(6.dp))
        Text("phone→Mac always works via Share ▸ Maccy Sync.", color = Hue.muted, style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(12.dp))
        Ghost(if (a11y) "Accessibility settings" else "Grant access") { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
      }
    }
  }
}

@Composable
private fun Card(title: String, content: @Composable () -> Unit) {
  Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Hue.surface).border(1.dp, Hue.border, RoundedCornerShape(20.dp)).padding(18.dp)) {
    Text(title, color = Hue.faint, style = MaterialTheme.typography.titleSmall)
    Spacer(Modifier.height(14.dp))
    content()
  }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
  Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
    Text(label, color = Hue.text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
    Switch(checked, onChange, colors = SwitchDefaults.colors(
      checkedThumbColor = Color.White, checkedTrackColor = Hue.blue,
      uncheckedThumbColor = Hue.muted, uncheckedTrackColor = Hue.surfaceHi, uncheckedBorderColor = Hue.border
    ))
  }
}

@Composable
private fun FieldRow(label: String, value: String, onChange: (String) -> Unit) {
  Column(Modifier.padding(vertical = 7.dp)) {
    Text(label, color = Hue.muted, style = MaterialTheme.typography.labelMedium)
    Spacer(Modifier.height(7.dp))
    TextField(value, onChange, singleLine = true, textStyle = MaterialTheme.typography.bodyLarge,
      modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)),
      colors = TextFieldDefaults.colors(
        focusedContainerColor = Hue.surfaceHi, unfocusedContainerColor = Hue.surfaceHi,
        focusedTextColor = Hue.text, unfocusedTextColor = Hue.text,
        focusedIndicatorColor = Hue.blue, unfocusedIndicatorColor = Color.Transparent, cursorColor = Hue.blue
      ))
  }
}

@Composable
private fun StatusLine(ok: Boolean, text: String) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Box(Modifier.size(8.dp).clip(CircleShape).background(if (ok) Color(0xFF7DE39B) else Hue.purple))
    Spacer(Modifier.width(10.dp))
    Text(text, color = Hue.muted, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
  }
}

@Composable
private fun Primary(label: String, onClick: () -> Unit) {
  Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Hue.heroGradient).clickable { onClick() }.padding(vertical = 13.dp), contentAlignment = Alignment.Center) {
    Text(label, color = Color.White, style = MaterialTheme.typography.labelLarge)
  }
}

@Composable
private fun Ghost(label: String, tint: Color = Hue.text, onClick: () -> Unit) {
  Box(Modifier.clip(RoundedCornerShape(12.dp)).border(1.dp, Hue.border, RoundedCornerShape(12.dp)).background(Hue.surfaceHi).clickable { onClick() }.padding(horizontal = 16.dp, vertical = 11.dp), contentAlignment = Alignment.Center) {
    Text(label, color = tint, style = MaterialTheme.typography.labelMedium)
  }
}

// MARK: bottom bar

@Composable
private fun BottomBar(onSettings: Boolean, onHome: () -> Unit, onOpenSettings: () -> Unit, modifier: Modifier = Modifier) {
  Row(
    modifier
      .navigationBarsPadding()
      .padding(horizontal = 28.dp, vertical = 16.dp)
      .fillMaxWidth()
      .shadow(20.dp, RoundedCornerShape(28.dp), spotColor = Hue.purple)
      .clip(RoundedCornerShape(28.dp))
      .background(Hue.surfaceHi)
      .border(1.dp, Hue.border, RoundedCornerShape(28.dp))
      .padding(horizontal = 40.dp, vertical = 12.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.SpaceBetween
  ) {
    NavIcon(Icons.Rounded.Notes, active = !onSettings, onHome)
    NavIcon(Icons.Rounded.Settings, active = onSettings, onOpenSettings)
  }
}

@Composable
private fun NavIcon(icon: ImageVector, active: Boolean, onClick: () -> Unit) {
  Box(Modifier.size(46.dp).clip(CircleShape).clickable { onClick() }, contentAlignment = Alignment.Center) {
    Icon(icon, null, tint = if (active) Hue.text else Hue.faint, modifier = Modifier.size(23.dp))
  }
}

// MARK: helpers

private fun kindIcon(kind: String): ImageVector = when (kind) {
  "image" -> Icons.Rounded.Image
  "file" -> Icons.Rounded.Description
  else -> Icons.Rounded.Notes
}

private fun subtitle(clip: ClipEntity): String {
  val rel = DateUtils.getRelativeTimeSpanString(clip.createdAt, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
  return when (clip.kind) {
    "image" -> "Image · $rel"
    "file" -> "${clip.filename ?: "File"} · $rel"
    else -> rel
  }
}

private fun isAccessibilityEnabled(context: Context): Boolean {
  val expected = ComponentName(context, ClipboardAccessibilityService::class.java).flattenToString()
  val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
  return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
}

private fun isBatteryExempt(context: Context): Boolean {
  val pm = context.getSystemService(PowerManager::class.java) ?: return false
  return pm.isIgnoringBatteryOptimizations(context.packageName)
}
