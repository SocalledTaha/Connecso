package com.connecso.client.tunnel

internal object ContunNative {
    external fun nativeStart(service: Any?, fd: Int, config: String?): Int
    external fun nativeStop()
    external fun nativeVersion(): String
    external fun nativeCounter(index: Int): Long
    external fun nativeIsRunning(): Boolean
    external fun nativeLastError(): Int

    init {
        System.loadLibrary("zeptun-jni")
    }
}
