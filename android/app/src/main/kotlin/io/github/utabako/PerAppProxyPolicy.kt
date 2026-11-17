package io.github.utabako

import org.json.JSONArray
import org.json.JSONObject

internal enum class PerAppProxyMode(val wireValue: String) {
    ALL("all"),
    INCLUDE("include"),
    EXCLUDE("exclude");

    companion object {
        fun fromWireValue(value: String): PerAppProxyMode =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("Unknown per-app proxy mode: $value")
    }
}

internal data class PerAppProxyPolicy(
    val mode: PerAppProxyMode,
    val packages: List<String>
) {
    init {
        require(mode != PerAppProxyMode.INCLUDE || packages.isNotEmpty()) {
            "Include mode requires at least one application"
        }
    }

    fun toJson(): String = JSONObject().apply {
        put("mode", mode.wireValue)
        put("packages", JSONArray().apply { packages.forEach { put(it) } })
    }.toString()

    companion object {
        val ALL = PerAppProxyPolicy(PerAppProxyMode.ALL, emptyList())

        fun parse(json: String): PerAppProxyPolicy {
            val value = JSONObject(json)
            val mode = PerAppProxyMode.fromWireValue(value.optString("mode", "all"))
            val packages = value.optJSONArray("packages")?.let { array ->
                buildList {
                    for (index in 0 until array.length()) {
                        val packageName = array.getString(index).trim()
                        if (packageName.isNotEmpty()) add(packageName)
                    }
                }.distinct()
            } ?: emptyList()
            return PerAppProxyPolicy(
                mode = mode,
                packages = if (mode == PerAppProxyMode.ALL) emptyList() else packages
            )
        }
    }
}
