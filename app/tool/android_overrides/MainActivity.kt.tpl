package __PKG__

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val aliases = mapOf("default" to "IconDefault", "a" to "IconA", "b" to "IconB", "c" to "IconC")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
