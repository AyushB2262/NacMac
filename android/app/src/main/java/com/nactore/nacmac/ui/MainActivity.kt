package com.nactore.nacmac.ui

import android.Manifest
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import android.content.res.Configuration
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.nactore.nacmac.R
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.data.PairedMac
import com.nactore.nacmac.model.PairingQRPayload
import com.nactore.nacmac.network.ConnectionManager
import com.nactore.nacmac.network.ConnectionStatus
import com.nactore.nacmac.service.NacMacBackgroundService
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private lateinit var deviceStore: DeviceStore
    private lateinit var connectionManager: ConnectionManager

    private lateinit var txtDeviceName: TextView
    private lateinit var badgeConnected: TextView
    private lateinit var txtDevicePath: TextView
    private lateinit var btnDisconnect: Button
    private lateinit var switchAutoConnect: SwitchCompat
    private lateinit var btnScanQR: Button
    private lateinit var btnSendFile: Button
    private lateinit var txtTransferItemName: TextView
    private lateinit var progressTransfer: ProgressBar
    private lateinit var txtTransferSpeed: TextView
    private lateinit var switchNotifMirroring: SwitchCompat

    private val filePickerLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri?.let {
            Toast.makeText(this, "Sending file to Mac...", Toast.LENGTH_SHORT).show()
            txtTransferItemName.text = "Sending selected file..."
            progressTransfer.visibility = View.VISIBLE
            progressTransfer.progress = 0
            
            connectionManager.fileTransferWorker?.sendFileToMac(it) { percent ->
                runOnUiThread {
                    progressTransfer.progress = percent
                    txtTransferItemName.text = "Sending file... $percent%"
                    txtTransferSpeed.text = "Streaming chunks"
                    if (percent >= 100) {
                        txtTransferItemName.text = "Sent - SHA-256 Verified"
                        txtTransferSpeed.text = "Complete"
                    }
                }
            }
        }
    }

    private val qrScannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            val rawJson = result.data?.getStringExtra("paired_json")
            if (rawJson != null) {
                val payload = PairingQRPayload.fromJSON(rawJson)
                if (payload != null) {
                    val primaryIp = payload.ips.firstOrNull { it != "127.0.0.1" } ?: payload.ips.firstOrNull() ?: "127.0.0.1"
                    deviceStore.savePairedMac(
                        PairedMac(
                            macId = payload.macId,
                            macName = payload.macName,
                            lastKnownIp = primaryIp,
                            port = payload.port,
                            secret = payload.secret
                        )
                    )
                    Toast.makeText(this, "Paired with ${payload.macName}!", Toast.LENGTH_SHORT).show()
                    connectionManager.startAutoConnect()
                }
            }
        }
    }

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ ->
        startBackgroundService()
    }

    private fun checkNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val themeMode = getSharedPreferences("nacmac_prefs", Context.MODE_PRIVATE)
            .getInt("theme_mode", AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
        AppCompatDelegate.setDefaultNightMode(themeMode)

        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        deviceStore = DeviceStore(this)
        connectionManager = ConnectionManager.getInstance(this)

        initViews()
        setupListeners()
        checkNotificationPermission()
        startBackgroundService()
        handleIncomingShareIntent(intent)
        observeConnection()
    }

    private fun initViews() {
        txtDeviceName = findViewById(R.id.txtDeviceName)
        badgeConnected = findViewById(R.id.badgeConnected)
        txtDevicePath = findViewById(R.id.txtDevicePath)
        btnDisconnect = findViewById(R.id.btnDisconnect)
        switchAutoConnect = findViewById(R.id.switchAutoConnect)
        btnScanQR = findViewById(R.id.btnScanQR)
        btnSendFile = findViewById(R.id.btnSendFile)
        txtTransferItemName = findViewById(R.id.txtTransferItemName)
        progressTransfer = findViewById(R.id.progressTransfer)
        txtTransferSpeed = findViewById(R.id.txtTransferSpeed)
        switchNotifMirroring = findViewById(R.id.switchNotifMirroring)

        val isNight = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        findViewById<ImageView>(R.id.btnThemeToggle)?.setImageResource(
            if (isNight) R.drawable.ic_sun else R.drawable.ic_moon
        )
    }

    private fun View.applyApplePressEffect(onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
        setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    v.animate()
                        .scaleX(0.965f)
                        .scaleY(0.965f)
                        .setDuration(90)
                        .setInterpolator(DecelerateInterpolator())
                        .start()
                    v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                }
                MotionEvent.ACTION_UP -> {
                    v.animate()
                        .scaleX(1.0f)
                        .scaleY(1.0f)
                        .setDuration(160)
                        .setInterpolator(OvershootInterpolator(1.4f))
                        .start()
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.animate()
                        .scaleX(1.0f)
                        .scaleY(1.0f)
                        .setDuration(120)
                        .setInterpolator(DecelerateInterpolator())
                        .start()
                }
                MotionEvent.ACTION_MOVE -> {
                    val isInside = event.x in 0f..v.width.toFloat() && event.y in 0f..v.height.toFloat()
                    if (!isInside) {
                        v.animate()
                            .scaleX(1.0f)
                            .scaleY(1.0f)
                            .setDuration(120)
                            .setInterpolator(DecelerateInterpolator())
                            .start()
                    }
                }
            }
            false
        }
        setOnClickListener { onClick() }
        if (onLongClick != null) {
            setOnLongClickListener {
                onLongClick()
                true
            }
        }
    }

    private fun setupListeners() {
        btnDisconnect.applyApplePressEffect {
            deviceStore.unpair()
            connectionManager.disconnect()
            updateDisconnectedUI()
            Toast.makeText(this, "Device disconnected and unpaired", Toast.LENGTH_SHORT).show()
        }

        val openScanner = {
            val intent = Intent(this, QRScannerActivity::class.java)
            qrScannerLauncher.launch(intent)
        }

        btnScanQR.applyApplePressEffect(
            onLongClick = { showPairingDialog() },
            onClick = { openScanner() }
        )

        val launchFilePicker = {
            if (connectionManager.status.value is ConnectionStatus.Connected) {
                filePickerLauncher.launch("*/*")
            } else {
                Toast.makeText(this, "Connect to Mac first to send files", Toast.LENGTH_SHORT).show()
            }
        }

        btnSendFile.applyApplePressEffect { launchFilePicker() }

        switchNotifMirroring.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked) {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }

        findViewById<View>(R.id.btnHelp)?.applyApplePressEffect {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://nactore.com"))
            startActivity(intent)
        }

        findViewById<View>(R.id.btnThemeToggle)?.applyApplePressEffect {
            toggleTheme()
        }

        findViewById<View>(R.id.btnSettings)?.applyApplePressEffect {
            showSettingsDialog()
        }
    }

    private fun toggleTheme() {
        val currentMode = AppCompatDelegate.getDefaultNightMode()
        val isCurrentlyNight = when (currentMode) {
            AppCompatDelegate.MODE_NIGHT_YES -> true
            AppCompatDelegate.MODE_NIGHT_NO -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        val nextMode = if (isCurrentlyNight) AppCompatDelegate.MODE_NIGHT_NO else AppCompatDelegate.MODE_NIGHT_YES
        getSharedPreferences("nacmac_prefs", Context.MODE_PRIVATE)
            .edit()
            .putInt("theme_mode", nextMode)
            .apply()
        AppCompatDelegate.setDefaultNightMode(nextMode)
        recreate()
    }

    private fun showSettingsDialog() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (18 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad / 2)
        }

        val txtDeviceLabel = TextView(this).apply {
            text = "Device Name"
            textSize = 12f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
        }
        val editDeviceName = EditText(this).apply {
            setText(deviceStore.deviceName)
            textSize = 15f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_primary))
        }

        val txtThemeLabel = TextView(this).apply {
            text = "Appearance Theme"
            textSize = 12f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            val topPad = (12 * resources.displayMetrics.density).toInt()
            setPadding(0, topPad, 0, 4)
        }

        val currentNight = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val btnSwitchTheme = Button(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = if (currentNight) "Switch to Light Mode" else "Switch to Dark Mode (Mac Slate)"
            setOnClickListener {
                toggleTheme()
            }
        }

        val txtInfo = TextView(this).apply {
            text = "Bonjour: _nacmac._tcp. • Port: 52840\nVersion: 0.2.0 • Nactore (nactore.com)"
            textSize = 12f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            val topPad = (14 * resources.displayMetrics.density).toInt()
            setPadding(0, topPad, 0, 0)
        }

        layout.addView(txtDeviceLabel)
        layout.addView(editDeviceName)
        layout.addView(txtThemeLabel)
        layout.addView(btnSwitchTheme)
        layout.addView(txtInfo)

        AlertDialog.Builder(this)
            .setTitle("NacMac Settings")
            .setView(layout)
            .setPositiveButton("Save") { _, _ ->
                val newName = editDeviceName.text.toString().trim()
                if (newName.isNotEmpty()) {
                    deviceStore.deviceName = newName
                    Toast.makeText(this, "Device name updated to $newName", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .setNeutralButton("Reset Pairing") { _, _ ->
                deviceStore.unpair()
                connectionManager.disconnect()
                updateDisconnectedUI()
                Toast.makeText(this, "Pairing reset", Toast.LENGTH_SHORT).show()
            }
            .show()
    }

    private fun startBackgroundService() {
        val serviceIntent = Intent(this, NacMacBackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(this, serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun observeConnection() {
        lifecycleScope.launch {
            connectionManager.status.collectLatest { status ->
                when (status) {
                    is ConnectionStatus.Connected -> {
                        txtDeviceName.text = status.macName
                        badgeConnected.visibility = View.VISIBLE
                        badgeConnected.text = "✔ Connected & Online"
                        badgeConnected.backgroundTintList = android.content.res.ColorStateList.valueOf(0xFFDCFCE7.toInt())
                        badgeConnected.setTextColor(0xFF15803D.toInt())
                        txtDevicePath.text = "Local ID: ~/.nacmac/paired_device.json (${status.ip})"
                        btnDisconnect.visibility = View.VISIBLE
                    }
                    is ConnectionStatus.Connecting -> {
                        txtDeviceName.text = status.target
                        badgeConnected.visibility = View.VISIBLE
                        badgeConnected.text = "Connecting..."
                        badgeConnected.backgroundTintList = android.content.res.ColorStateList.valueOf(0xFFFEF9C3.toInt())
                        badgeConnected.setTextColor(0xFFA16207.toInt())
                        txtDevicePath.text = "Searching local Wi-Fi..."
                        btnDisconnect.visibility = View.VISIBLE
                    }
                    is ConnectionStatus.Disconnected -> {
                        if (deviceStore.isPaired) {
                            val mac = deviceStore.getPairedMac()
                            txtDeviceName.text = mac?.macName ?: "Mac"
                            badgeConnected.visibility = View.VISIBLE
                            badgeConnected.text = "Standby"
                            badgeConnected.backgroundTintList = android.content.res.ColorStateList.valueOf(0xFFF1F5F9.toInt())
                            badgeConnected.setTextColor(0xFF64748B.toInt())
                            txtDevicePath.text = "Local ID: ~/.nacmac/paired_device.json"
                            btnDisconnect.visibility = View.VISIBLE
                        } else {
                            updateDisconnectedUI()
                        }
                    }
                }
            }
        }
    }

    private fun updateDisconnectedUI() {
        txtDeviceName.text = "No Paired Device"
        badgeConnected.visibility = View.GONE
        txtDevicePath.text = "Scan QR code on your Mac to connect."
        btnDisconnect.visibility = View.GONE
    }

    private fun showPairingDialog() {
        val input = EditText(this)
        input.hint = "Paste Pairing Payload JSON from Mac"

        AlertDialog.Builder(this)
            .setTitle("Pair with Mac")
            .setMessage("Position your camera over the QR code on your Mac, or paste the pairing payload JSON below:")
            .setView(input)
            .setPositiveButton("Pair") { _, _ ->
                val text = input.text.toString().trim()
                val payload = PairingQRPayload.fromJSON(text)
                if (payload != null) {
                    val primaryIp = payload.ips.firstOrNull { it != "127.0.0.1" } ?: payload.ips.firstOrNull() ?: "127.0.0.1"
                    deviceStore.savePairedMac(
                        PairedMac(
                            macId = payload.macId,
                            macName = payload.macName,
                            lastKnownIp = primaryIp,
                            port = payload.port,
                            secret = payload.secret
                        )
                    )
                    Toast.makeText(this, "Paired with ${payload.macName}!", Toast.LENGTH_SHORT).show()
                    connectionManager.startAutoConnect()
                } else {
                    Toast.makeText(this, "Invalid pairing payload format", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun handleIncomingShareIntent(intent: Intent?) {
        if (intent == null) return
        
        // Handle pairing payload intent
        val pairRaw = intent.getStringExtra("pair_payload") ?: intent.getStringExtra("pair_payload_b64")
        if (pairRaw != null) {
            val text = try {
                if (pairRaw.trim().startsWith("{")) {
                    pairRaw.trim()
                } else {
                    String(android.util.Base64.decode(pairRaw, android.util.Base64.DEFAULT), Charsets.UTF_8)
                }
            } catch (e: Exception) {
                pairRaw
            }
            
            val payload = PairingQRPayload.fromJSON(text)
            if (payload != null) {
                val primaryIp = payload.ips.firstOrNull { it == "10.0.2.2" }
                    ?: payload.ips.firstOrNull { it != "127.0.0.1" } ?: "10.0.2.2"
                deviceStore.savePairedMac(
                    PairedMac(
                        macId = payload.macId,
                        macName = payload.macName,
                        lastKnownIp = primaryIp,
                        port = payload.port,
                        secret = payload.secret
                    )
                )
                Toast.makeText(this, "Paired with ${payload.macName}!", Toast.LENGTH_SHORT).show()
                connectionManager.startAutoConnect()
            }
        }
        
        if (Intent.ACTION_SEND == intent.action) {
            val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            uri?.let {
                connectionManager.fileTransferWorker?.sendFileToMac(it)
                Toast.makeText(this, "Sending shared file to Mac...", Toast.LENGTH_SHORT).show()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingShareIntent(intent)
    }
}
