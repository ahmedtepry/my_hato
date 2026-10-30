package __PKG__

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val aliases = mapOf("default" to "IconDefault", "a" to "IconA", "b" to "IconB", "c" to "IconC",
        "bird" to "IconBird", "pulse" to "IconPulse", "phone" to "IconPhone", "neon" to "IconNeon", "orbit" to "IconOrbit", "liquid" to "IconLiquid",
        "w1n" to "IconW1N", "w1e" to "IconW1E", "w1l" to "IconW1L", "w2n" to "IconW2N", "w2e" to "IconW2E", "w2l" to "IconW2L", "w3n" to "IconW3N", "w3e" to "IconW3E", "w3l" to "IconW3L", "w4n" to "IconW4N", "w4e" to "IconW4E", "w4l" to "IconW4L", "w5n" to "IconW5N", "w5e" to "IconW5E", "w5l" to "IconW5L", "w6n" to "IconW6N", "w6e" to "IconW6E", "w6l" to "IconW6L", "w7n" to "IconW7N", "w7e" to "IconW7E", "w7l" to "IconW7L", "w8n" to "IconW8N", "w8e" to "IconW8E", "w8l" to "IconW8L", "w9n" to "IconW9N", "w9e" to "IconW9E", "w9l" to "IconW9L", "w10n" to "IconW10N", "w10e" to "IconW10E", "w10l" to "IconW10L")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // in-app update: the app downloads the new APK into the cache folder, then asks Android to install it over the old one
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "myhato/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "install" -> {
                    try {
                        val path = call.arguments as String
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            // the member must allow "install unknown apps" for My Hato once
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success("need_permission")
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
                            val i = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success("started")
                        }
                    } catch (e: Exception) {
                        result.error("INSTALL", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "myhato/icon").setMethodCallHandler { call, result ->
            if (call.method != "set") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val want = call.arguments as? String ?: "default"
            if (!aliases.containsKey(want)) {
                result.success(false)
                return@setMethodCallHandler
            }
            try {
                val pkg = MainActivity::class.java.`package`!!.name
                // switch the wanted one on first, then switch the others off, so the app is never left without a launcher icon
                val order = aliases.entries.sortedBy { if (it.key == want) 0 else 1 }
                for ((key, name) in order) {
                    packageManager.setComponentEnabledSetting(
                        ComponentName(this, "$pkg.$name"),
                        if (key == want) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        PackageManager.DONT_KILL_APP
                    )
                }
                result.success(true)
            } catch (e: Exception) {
                result.success(false)
            }
        }
    }
}
