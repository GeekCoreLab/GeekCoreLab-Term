package cn.geekcorelab.geekcore_term

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val portKnockExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cn.geekcorelab.geekcore_term/port_knock",
        ).setMethodCallHandler { call, result ->
            if (call.method != "icmpEcho") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val host = call.argument<String>("host")?.trim()
            if (host.isNullOrEmpty()) {
                result.error("invalid_host", "ICMP 目标主机不能为空", null)
                return@setMethodCallHandler
            }
            portKnockExecutor.execute {
                try {
                    val process = ProcessBuilder(
                        "/system/bin/ping",
                        "-c",
                        "1",
                        "-W",
                        "2",
                        host,
                    ).redirectErrorStream(true).start()
                    if (!process.waitFor(5, TimeUnit.SECONDS)) {
                        process.destroyForcibly()
                        throw IllegalStateException("ICMP 敲门超时")
                    }
                    val output = process.inputStream.bufferedReader().use { it.readText() }
                    val exitCode = process.exitValue()
                    if (exitCode == 0 || exitCode == 1) {
                        mainHandler.post { result.success(null) }
                    } else {
                        mainHandler.post {
                            result.error(
                                "icmp_failed",
                                output.trim().ifEmpty { "ICMP 敲门失败" },
                                null,
                            )
                        }
                    }
                } catch (error: Exception) {
                    mainHandler.post {
                        result.error(
                            "icmp_failed",
                            error.message ?: "ICMP 敲门失败",
                            null,
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        portKnockExecutor.shutdownNow()
        super.onDestroy()
    }
}
