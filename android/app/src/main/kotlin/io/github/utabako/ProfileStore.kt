package io.github.utabako

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

internal class ProfileStore(context: Context) {
    private val filesDir = context.applicationContext.filesDir
    private val profilesDir = File(filesDir, "sing-box/profiles").also { it.mkdirs() }
    private val metaFile = File(filesDir, "sing-box/profiles_meta.json")

    fun list(): JSONObject = readMetadata()

    fun get(id: String): String? {
        val file = profileFile(id)
        return if (file.exists()) file.readText() else null
    }

    fun getActiveConfig(): String? {
        val activeId = readMetadata().optString("activeId")
        return activeId.takeIf { it.isNotEmpty() }?.let(::get)
    }

    fun save(id: String?, name: String, config: String, url: String?): String {
        val profileId = id ?: UUID.randomUUID().toString()
        val profileFile = profileFile(profileId)
        val previousConfig = if (profileFile.exists()) profileFile.readText() else null
        val metadata = readMetadata()
        val profiles = metadata.getJSONArray("profiles")
        val existingProfile = (0 until profiles.length())
            .map(profiles::getJSONObject)
            .firstOrNull { it.getString("id") == profileId }
        val profile = existingProfile ?: JSONObject().apply {
            put("id", profileId)
            profiles.put(this)
            if (metadata.optString("activeId").isEmpty()) {
                metadata.put("activeId", profileId)
            }
        }
        profile.put("name", name)
        if (url == null) profile.remove("url") else profile.put("url", url)
        profile.put("updatedAt", System.currentTimeMillis())

        try {
            writeAtomic(profileFile, config)
            writeMetadata(metadata)
            return profileId
        } catch (error: Throwable) {
            try {
                if (previousConfig == null) {
                    profileFile.delete()
                } else {
                    writeAtomic(profileFile, previousConfig)
                }
            } catch (rollbackError: Throwable) {
                error.addSuppressed(rollbackError)
            }
            throw error
        }
    }

    fun delete(id: String) {
        val metadata = readMetadata()
        val profiles = metadata.getJSONArray("profiles")
        for (index in 0 until profiles.length()) {
            if (profiles.getJSONObject(index).getString("id") == id) {
                profiles.remove(index)
                break
            }
        }
        if (metadata.optString("activeId") == id) {
            val nextActiveId = if (profiles.length() == 0) {
                ""
            } else {
                profiles.getJSONObject(0).getString("id")
            }
            metadata.put("activeId", nextActiveId)
        }
        writeMetadata(metadata)
        profileFile(id).delete()
    }

    fun setActive(id: String) {
        require(profileFile(id).exists()) { "Profile does not exist: $id" }
        val metadata = readMetadata()
        metadata.put("activeId", id)
        writeMetadata(metadata)
    }

    private fun readMetadata(): JSONObject = if (metaFile.exists()) {
        JSONObject(metaFile.readText())
    } else {
        JSONObject().apply {
            put("activeId", "")
            put("profiles", JSONArray())
        }
    }

    private fun writeMetadata(metadata: JSONObject) {
        writeAtomic(metaFile, metadata.toString(2))
    }

    private fun profileFile(id: String): File {
        require(PROFILE_ID.matches(id) && id != "." && id != "..") {
            "Invalid profile ID"
        }
        return File(profilesDir, "$id.json")
    }

    private fun writeAtomic(file: File, content: String) {
        file.parentFile?.mkdirs()
        val atomicFile = AtomicFile(file)
        var output: FileOutputStream? = null
        try {
            output = atomicFile.startWrite()
            output.write(content.toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(output)
        } catch (error: Throwable) {
            if (output != null) atomicFile.failWrite(output)
            throw error
        }
    }

    companion object {
        private val PROFILE_ID = Regex("[A-Za-z0-9._-]+")
    }
}
