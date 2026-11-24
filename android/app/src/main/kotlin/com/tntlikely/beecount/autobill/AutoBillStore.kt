package com.tntlikely.beecount.autobill

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 原生侧轻量持久化存储：
 * - 无感记账开关
 * - 跨进程/后台待同步队列（App 被回收时也不丢单）
 * - 用户自定义的「关键词 -> 账户名」映射摘要（供灵动胶囊即时展示）
 * - 最近 30 条捕获与去重调试日志
 */
object AutoBillStore {
    private const val PREFS_NAME = "plainledger_auto_bill"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PENDING_EVENTS = "pending_events"
    private const val KEY_ACCOUNT_MAPPINGS = "account_mappings"
    private const val KEY_RECENT_LOGS = "recent_logs"
    private const val MAX_LOGS = 30

    private val lock = Any()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun upsertPendingEvent(context: Context, event: Map<String, Any>) {
        synchronized(lock) {
            val sp = prefs(context)
            val arr = try {
                JSONArray(sp.getString(KEY_PENDING_EVENTS, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            val eventId = event["eventId"] as? String ?: return
            val obj = JSONObject()
            for ((k, v) in event) {
                obj.put(k, v)
            }

            var replaced = false
            val next = JSONArray()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                if (item.optString("eventId") == eventId) {
                    next.put(obj)
                    replaced = true
                } else {
                    next.put(item)
                }
            }
            if (!replaced) {
                next.put(obj)
            }
            sp.edit().putString(KEY_PENDING_EVENTS, next.toString()).apply()
        }
    }

    fun drainPendingEvents(context: Context): List<Map<String, Any>> {
        synchronized(lock) {
            val sp = prefs(context)
            val raw = sp.getString(KEY_PENDING_EVENTS, "[]") ?: "[]"
            sp.edit().putString(KEY_PENDING_EVENTS, "[]").apply()
            val result = mutableListOf<Map<String, Any>>()
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val map = mutableMapOf<String, Any>()
                    val keys = obj.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        map[key] = obj.get(key)
                    }
                    result.add(map)
                }
            } catch (_: Exception) {
            }
            return result
        }
    }

    fun saveAccountMappings(context: Context, mappings: List<Map<String, Any>>) {
        synchronized(lock) {
            val arr = JSONArray()
            for (m in mappings) {
                val obj = JSONObject()
                obj.put("keyword", m["keyword"]?.toString() ?: "")
                obj.put("accountName", m["accountName"]?.toString() ?: "")
                arr.put(obj)
            }
            prefs(context).edit().putString(KEY_ACCOUNT_MAPPINGS, arr.toString()).apply()
        }
    }

    fun resolveMappedAccountLabel(
        context: Context,
        rawText: String,
        accountHint: String?,
        cardLastFour: String?,
    ): String? {
        synchronized(lock) {
            val raw = prefs(context).getString(KEY_ACCOUNT_MAPPINGS, "[]") ?: "[]"
            val haystack = listOfNotNull(accountHint, cardLastFour, rawText)
                .joinToString("\n")
                .lowercase(Locale.ROOT)
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val kw = obj.optString("keyword").trim().lowercase(Locale.ROOT)
                    val name = obj.optString("accountName").trim()
                    if (kw.isNotEmpty() && name.isNotEmpty() && haystack.contains(kw)) {
                        return name
                    }
                }
            } catch (_: Exception) {
            }
            return accountHint
        }
    }

    fun appendLog(context: Context, source: String, message: String) {
        synchronized(lock) {
            val sp = prefs(context)
            val arr = try {
                JSONArray(sp.getString(KEY_RECENT_LOGS, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
            val entry = "[$time][$source] $message"
            val next = JSONArray()
            next.put(entry)
            val limit = minOf(arr.length(), MAX_LOGS - 1)
            for (i in 0 until limit) {
                next.put(arr.optString(i))
            }
            sp.edit().putString(KEY_RECENT_LOGS, next.toString()).apply()
        }
    }

    fun getRecentLogs(context: Context): List<String> {
        synchronized(lock) {
            val raw = prefs(context).getString(KEY_RECENT_LOGS, "[]") ?: "[]"
            val result = mutableListOf<String>()
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    result.add(arr.optString(i))
                }
            } catch (_: Exception) {
            }
            return result
        }
    }

    fun clearRecentLogs(context: Context) {
        synchronized(lock) {
            prefs(context).edit().putString(KEY_RECENT_LOGS, "[]").apply()
        }
    }
}
