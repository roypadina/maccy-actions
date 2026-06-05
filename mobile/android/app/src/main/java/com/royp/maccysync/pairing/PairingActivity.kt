package com.royp.maccysync.pairing

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.net.SyncForegroundService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class PairingActivity : ComponentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setContent {
      MaterialTheme {
        PairingScreen(onDone = { finish() })
      }
    }
  }
}

@Composable
private fun PairingScreen(onDone: () -> Unit) {
  val context = LocalContext.current
  val activity = context as ComponentActivity
  var hasCamera by remember {
    mutableStateOf(
      ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    )
  }
  val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
    hasCamera = it
  }
  LaunchedEffect(Unit) { if (!hasCamera) launcher.launch(Manifest.permission.CAMERA) }

  var status by remember { mutableStateOf("Point at the QR in Maccy ▸ Settings ▸ Sync ▸ Pair") }
  val handled = remember { AtomicBoolean(false) }

  fun onQr(raw: String) {
    if (!handled.compareAndSet(false, true)) return
    val payload = QrParser.parse(raw)
    if (payload == null) {
      handled.set(false)
      activity.runOnUiThread { status = "Not a Maccy pairing code" }
      return
    }
    activity.runOnUiThread { status = "Pairing with ${payload.name}…" }
    MaccyApp.from(context).controller.startPairing(payload) { success, error ->
      activity.runOnUiThread {
        if (success) {
          SyncForegroundService.start(context)
          status = "Paired!"
          onDone()
        } else {
          handled.set(false)
          status = "Pairing failed: ${error ?: "unknown"}"
        }
      }
    }
  }

  Column(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    Text("Pair with Mac", style = MaterialTheme.typography.headlineSmall)
    if (hasCamera) {
      QrCameraView(modifier = Modifier.fillMaxWidth().weight(1f), onQr = ::onQr)
    } else {
      Text("Camera permission is required to scan the pairing code.", modifier = Modifier.weight(1f))
    }
    Text(status)
    Button(onClick = onDone) { Text("Cancel") }
  }
}

@OptIn(ExperimentalGetImage::class)
@Composable
private fun QrCameraView(modifier: Modifier, onQr: (String) -> Unit) {
  val context = LocalContext.current
  val lifecycleOwner = LocalLifecycleOwner.current
  val previewView = remember { PreviewView(context) }
  val executor = remember { Executors.newSingleThreadExecutor() }
  val scanner = remember {
    BarcodeScanning.getClient(
      BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    )
  }

  AndroidView(factory = { previewView }, modifier = modifier)

  LaunchedEffect(Unit) {
    val provider = withContext(Dispatchers.IO) { ProcessCameraProvider.getInstance(context).get() }
    val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
    val analysis = ImageAnalysis.Builder()
      .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
      .build()
    analysis.setAnalyzer(executor) { proxy ->
      val media = proxy.image
      if (media == null) { proxy.close(); return@setAnalyzer }
      val input = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
      scanner.process(input)
        .addOnSuccessListener { codes -> codes.firstOrNull()?.rawValue?.let(onQr) }
        .addOnCompleteListener { proxy.close() }
    }
    runCatching {
      provider.unbindAll()
      provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
    }
  }
}
