package io.github.utabako

import android.content.Context
import android.util.Log
import libbox.Libbox
import libbox.SetupOptions
import java.io.File

internal object LibboxRuntime {
    @Volatile
    private var initialized = false

    fun ensureInitialized(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val appContext = context.applicationContext
            val options = SetupOptions().apply {
                basePath = appContext.filesDir.absolutePath
                workingPath = File(appContext.filesDir, "sing-box")
                    .also { it.mkdirs() }
                    .absolutePath
                tempPath = appContext.cacheDir.absolutePath
            }
            Libbox.setup(options)
            initialized = true
            Log.i("Utabako", "libbox setup done, version: ${Libbox.version()}")
        }
    }
}
