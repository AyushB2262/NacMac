package com.nactore.nacmac.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.widget.SwitchCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.nactore.nacmac.R
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.data.PairedMac
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.model.NotificationPayload
import com.nactore.nacmac.model.PairingQRPayload
import com.nactore.nacmac.model.TransferRecord
import com.nactore.nacmac.network.ConnectionManager
import com.nactore.nacmac.network.ConnectionStatus
import com.nactore.nacmac.service.NacMacBackgroundService
import com.nactore.nacmac.service.NacMacNotificationListener
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.io.File

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
    private lateinit var switchNotifMirroring: SwitchCompat
    private lateinit var txtNotifStatus: TextView
    private lateinit var cardNotificationMirroring: View

    // Transfer Views
    private lateinit var layoutActiveTransfer: View
    private lateinit var txtTransferItemName: TextView
    private lateinit var progressTransfer: ProgressBar
    private lateinit var txtTransferSpeed: TextView
    private lateinit var txtNoTransfers: TextView
    private lateinit var layoutTransfersList: LinearLayout
    private lateinit var layoutIntegrityBadge: View
    private lateinit var btnClearTransfers: TextView

    private val filePickerLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri?.let {
            Toast.makeText(this, "Sending file to Mac...", Toast.LENGTH_SHORT).show()
            connectionManager.fileTransferWorker?.sendFileToMac(it)
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
                    checkAndPromptNotificationAccess()
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
        observeTransfers()
    }

    override fun onResume() {
        super.onResume()
        updateNotificationMirroringUI()
    }

    private fun initViews() {
        txtDeviceName = findViewById(R.id.txtDeviceName)
        badgeConnected = findViewById(R.id.badgeConnected)
        txtDevicePath = findViewById(R.id.txtDevicePath)
        btnDisconnect = findViewById(R.id.btnDisconnect)
        switchAutoConnect = findViewById(R.id.switchAutoConnect)
        btnScanQR = findViewById(R.id.btnScanQR)
        btnSendFile = findViewById(R.id.btnSendFile)
        switchNotifMirroring = findViewById(R.id.switchNotifMirroring)
        txtNotifStatus = findViewById(R.id.txtNotifStatus)
        cardNotificationMirroring = findViewById(R.id.cardNotificationMirroring)

        // Transfer views
        layoutActiveTransfer = findViewById(R.id.layoutActiveTransfer)
        txtTransferItemName = findViewById(R.id.txtTransferItemName)
        progressTransfer = findViewById(R.id.progressTransfer)
        txtTransferSpeed = findViewById(R.id.txtTransferSpeed)
        txtNoTransfers = findViewById(R.id.txtNoTransfers)
        layoutTransfersList = findViewById(R.id.layoutTransfersList)
        layoutIntegrityBadge = findViewById(R.id.layoutIntegrityBadge)
        btnClearTransfers = findViewById(R.id.btnClearTransfers)

        val isNight = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        findViewById<ImageView>(R.id.btnThemeToggle)?.setImageResource(
            if (isNight) R.drawable.ic_sun else R.drawable.ic_moon
        )
    }

    private fun isNotificationAccessGranted(): Boolean {
        val pkgName = packageName
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        if (!flat.isNullOrEmpty()) {
            val names = flat.split(":")
            for (name in names) {
                val cn = ComponentName.unflattenFromString(name)
                if (cn != null && cn.packageName == pkgName) {
                    return true
                }
            }
        }
        return NotificationManagerCompat.getEnabledListenerPackages(this).contains(pkgName)
    }

    private fun updateNotificationMirroringUI() {
        val isGranted = isNotificationAccessGranted()
        switchNotifMirroring.setOnCheckedChangeListener(null)
        switchNotifMirroring.isChecked = isGranted

        if (isGranted) {
            txtNotifStatus.text = "Active • All phone notifications mirror live to Mac"
            txtNotifStatus.setTextColor(ContextCompat.getColor(this, R.color.text_secondary))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    NotificationListenerService.requestRebind(ComponentName(this, NacMacNotificationListener::class.java))
                } catch (_: Exception) {}
            }
        } else {
            txtNotifStatus.text = "⚠️ Tap to enable Notification Access in Settings"
            txtNotifStatus.setTextColor(0xFFEA580C.toInt()) // Warm Amber-Orange warning
        }

        switchNotifMirroring.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked && !isNotificationAccessGranted()) {
                showNotificationPermissionDialog()
            } else if (!isChecked && isNotificationAccessGranted()) {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }
    }

    private fun checkAndPromptNotificationAccess() {
        if (!isNotificationAccessGranted()) {
            showNotificationPermissionDialog()
        }
    }

    private fun showNotificationPermissionDialog() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (20 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad / 2)
            gravity = android.view.Gravity.CENTER_HORIZONTAL
        }

        val imgLogo = ImageView(this).apply {
            setImageResource(R.drawable.ic_nacmac_logo)
            val sz = (52 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(sz, sz).apply {
                bottomMargin = (14 * resources.displayMetrics.density).toInt()
            }
            contentDescription = "NacMac"
        }

        val txtDesc = TextView(this).apply {
            text = "NacMac needs Notification Access to forward your phone notifications to your Mac.\n\n" +
                   "1. Tap 'Open Settings' below.\n" +
                   "2. Find 'NacMac Notification Service' and toggle it ON.\n\n" +
                   "💡 Android 13/14/15 Note: If the toggle is greyed out ('Restricted setting'), open NacMac App Info > 3 dots (top right) > 'Allow restricted settings' first."
            textSize = 13.5f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            setLineSpacing(4f, 1.2f)
        }

        layout.addView(imgLogo)
        layout.addView(txtDesc)

        AlertDialog.Builder(this)
            .setTitle("Enable Notification Mirroring")
            .setView(layout)
            .setPositiveButton("Open Settings") { _, _ ->
                try {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                } catch (e: Exception) {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                }
            }
            .setNegativeButton("Cancel") { _, _ ->
                updateNotificationMirroringUI()
            }
            .show()
    }

    private fun showNotificationTestDialog() {
        AlertDialog.Builder(this)
            .setTitle("Notification Mirroring Active")
            .setMessage("Notification Access is granted and active.\n\nWould you like to send a test notification to your Mac to verify the connection?")
            .setPositiveButton("Send Test Notification") { _, _ ->
                sendTestNotificationToMac()
            }
            .setNeutralButton("Settings") { _, _ ->
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
            .setNegativeButton("Close", null)
            .show()
    }

    fun sendTestNotificationToMac() {
        if (connectionManager.status.value !is ConnectionStatus.Connected) {
            Toast.makeText(this, "Connect to Mac first to send test notification", Toast.LENGTH_SHORT).show()
            return
        }
        val notif = NotificationPayload(
            id = "test_${System.currentTimeMillis()}",
            packageName = packageName,
            appName = "NacMac",
            title = "Test Notification",
            body = "Notification mirroring is active and verified with your phone!",
            iconBase64 = null,
            timestamp = System.currentTimeMillis() / 1000,
            hasReplyAction = false
        )
        val envelope = NacMacEnvelope(NacMacMessageType.NOTIFICATION, notif.toJSON().toString())
        connectionManager.sendEnvelope(envelope)
        Toast.makeText(this, "Test notification sent to Mac!", Toast.LENGTH_SHORT).show()
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

        cardNotificationMirroring.applyApplePressEffect {
            if (!isNotificationAccessGranted()) {
                showNotificationPermissionDialog()
            } else {
                showNotificationTestDialog()
            }
        }

        btnClearTransfers.setOnClickListener {
            connectionManager.fileTransferWorker?.clearHistory()
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
            val pad = (20 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad / 2)
        }

        // Top Brand Header with Logo
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            val bottomPad = (16 * resources.displayMetrics.density).toInt()
            setPadding(0, 0, 0, bottomPad)
        }
        val imgLogo = ImageView(this).apply {
            setImageResource(R.drawable.ic_nacmac_logo)
            val sz = (44 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(sz, sz).apply {
                marginEnd = (12 * resources.displayMetrics.density).toInt()
            }
            contentDescription = "NacMac Logo"
        }
        val headerTextLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val txtTitle = TextView(this).apply {
            text = "NacMac"
            textSize = 18f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_primary))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        val txtSubtitle = TextView(this).apply {
            text = "Android Companion v1.0.0"
            textSize = 12f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
        }
        headerTextLayout.addView(txtTitle)
        headerTextLayout.addView(txtSubtitle)
        header.addView(imgLogo)
        header.addView(headerTextLayout)
        layout.addView(header)

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

        val btnTestNotif = Button(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "Send Test Notification to Mac"
            setOnClickListener {
                sendTestNotificationToMac()
            }
            val topPad = (8 * resources.displayMetrics.density).toInt()
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = topPad
            }
            layoutParams = lp
        }

        val txtInfo = TextView(this).apply {
            text = "Bonjour: _nacmac._tcp. • Port: 52840\nVersion: 1.0.0 • Nactore (nactore.com)"
            textSize = 12f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            val topPad = (14 * resources.displayMetrics.density).toInt()
            setPadding(0, topPad, 0, 0)
        }

        layout.addView(txtDeviceLabel)
        layout.addView(editDeviceName)
        layout.addView(txtThemeLabel)
        layout.addView(btnSwitchTheme)
        layout.addView(btnTestNotif)
        layout.addView(txtInfo)

        AlertDialog.Builder(this)
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

    private fun observeTransfers() {
        val worker = connectionManager.fileTransferWorker ?: return

        // 1. Observe active transfers (both sending and receiving)
        lifecycleScope.launch {
            worker.activeTransfer.collectLatest { active ->
                if (active != null) {
                    layoutActiveTransfer.visibility = View.VISIBLE
                    txtTransferItemName.text = if (active.isIncoming) {
                        "Receiving ${active.filename}..."
                    } else {
                        "Sending ${active.filename}..."
                    }
                    progressTransfer.progress = active.percent
                    txtTransferSpeed.text = "${active.percent}% • ${if (active.isIncoming) "Incoming from Mac" else "Streaming to Mac"}"
                } else {
                    layoutActiveTransfer.visibility = View.GONE
                }
            }
        }

        // 2. Observe recent transfers list (sent & received history)
        lifecycleScope.launch {
            worker.recentTransfers.collectLatest { transfers ->
                renderRecentTransfers(transfers)
            }
        }
    }

    private fun renderRecentTransfers(transfers: List<TransferRecord>) {
        layoutTransfersList.removeAllViews()
        if (transfers.isEmpty()) {
            txtNoTransfers.visibility = View.VISIBLE
            layoutIntegrityBadge.visibility = View.GONE
            btnClearTransfers.visibility = View.GONE
            return
        }

        txtNoTransfers.visibility = View.GONE
        layoutIntegrityBadge.visibility = View.VISIBLE
        btnClearTransfers.visibility = View.VISIBLE

        for (record in transfers) {
            val itemView = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                val padV = (8 * resources.displayMetrics.density).toInt()
                setPadding(0, padV, 0, padV)
            }

            // Direction icon
            val icon = ImageView(this).apply {
                val iconRes = if (record.isIncoming) {
                    android.R.drawable.stat_sys_download_done
                } else {
                    android.R.drawable.stat_sys_upload_done
                }
                setImageResource(iconRes)
                val tintColor = if (record.isIncoming) 0xFF15803D.toInt() else 0xFFEA580C.toInt()
                setColorFilter(tintColor)
                val sz = (22 * resources.displayMetrics.density).toInt()
                layoutParams = LinearLayout.LayoutParams(sz, sz).apply {
                    marginEnd = (10 * resources.displayMetrics.density).toInt()
                }
            }

            val textLayout = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.0f)
            }

            val txtName = TextView(this).apply {
                text = record.name
                textSize = 13.5f
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_primary))
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                typeface = android.graphics.Typeface.DEFAULT_BOLD
            }

            val txtSub = TextView(this).apply {
                val dirStr = if (record.isIncoming) "Received from Mac" else "Sent to Mac"
                val sizeStr = if (record.sizeBytes > 0) " • ${formatFileSize(record.sizeBytes)}" else ""
                text = "(Verified) • $dirStr$sizeStr"
                textSize = 11.5f
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            }

            textLayout.addView(txtName)
            textLayout.addView(txtSub)

            // Right checkmark badge
            val checkBadge = TextView(this).apply {
                text = "✔"
                textSize = 13f
                setTextColor(0xFF15803D.toInt())
                val pad = (4 * resources.displayMetrics.density).toInt()
                setPadding(pad, pad, pad, pad)
            }

            itemView.addView(icon)
            itemView.addView(textLayout)
            itemView.addView(checkBadge)

            if (record.isIncoming) {
                itemView.applyApplePressEffect {
                    openDownloadsFolder()
                }
            }

            layoutTransfersList.addView(itemView)
        }
    }

    private fun formatFileSize(bytes: Long): String {
        if (bytes <= 0) return ""
        if (bytes < 1024) return "$bytes B"
        val exp = (Math.log(bytes.toDouble()) / Math.log(1024.0)).toInt()
        val pre = "KMGTPE"[exp - 1]
        return String.format("%.1f %sB", bytes / Math.pow(1024.0, exp.toDouble()), pre)
    }

    private fun openDownloadsFolder() {
        val downloadDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "NacMac"
        )
        if (!downloadDir.exists()) downloadDir.mkdirs()
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(downloadDir.absolutePath), "*/*")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
        } catch (_: Exception) {
            Toast.makeText(this, "Files saved in Downloads/NacMac", Toast.LENGTH_SHORT).show()
        }
    }

    private fun updateDisconnectedUI() {
        txtDeviceName.text = "No Paired Device"
        badgeConnected.visibility = View.GONE
        txtDevicePath.text = "Scan QR code on your Mac to connect."
        btnDisconnect.visibility = View.GONE
    }

    private fun showPairingDialog() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (18 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad / 2)
        }

        // Header with Logo
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            val bottomPad = (10 * resources.displayMetrics.density).toInt()
            setPadding(0, 0, 0, bottomPad)
        }
        val imgLogo = ImageView(this).apply {
            setImageResource(R.drawable.ic_nacmac_logo)
            val sz = (36 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(sz, sz).apply {
                marginEnd = (10 * resources.displayMetrics.density).toInt()
            }
            contentDescription = "NacMac"
        }
        val txtTitle = TextView(this).apply {
            text = "Pair with Mac"
            textSize = 17f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_primary))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        header.addView(imgLogo)
        header.addView(txtTitle)
        layout.addView(header)

        val txtDesc = TextView(this).apply {
            text = "Position your camera over the QR code on your Mac, or paste the pairing payload JSON below:"
            textSize = 13f
            setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
            val bottomPad = (8 * resources.displayMetrics.density).toInt()
            setPadding(0, 0, 0, bottomPad)
        }
        layout.addView(txtDesc)

        val input = EditText(this).apply {
            hint = "Paste Pairing Payload JSON from Mac"
            textSize = 13f
        }
        layout.addView(input)

        AlertDialog.Builder(this)
            .setView(layout)
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
                    checkAndPromptNotificationAccess()
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
                checkAndPromptNotificationAccess()
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
