package com.tntlikely.beecount.autobill

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 原生侧轻量持久化存储：
 * - 无感记账总开关 & 自动/确认模式开关
 * - 跨进程/后台待同步与待撤销队列（App 被回收时也不丢单/漏撤）
 * - 用户自定义的「关键词 -> 账户名」映射摘要（供侧边悬浮球即时展示）
 * - 悬浮球停靠纵向位置记忆 & 最近 30 条调试日志
 */
object AutoBillStore {
    private const val PREFS_NAME = "plainledger_auto_bill"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_AUTO_SAVE_ENABLED = "auto_save_enabled"
    private const val KEY_OVERLAY_Y_PX = "overlay_y_px"
    private const val KEY_PENDING_EVENTS = "pending_events"
    private const val KEY_PENDING_CANCEL_IDS = "pending_cancel_event_ids"
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

    fun isAutoSaveEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AUTO_SAVE_ENABLED, true)

    fun setAutoSaveEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_AUTO_SAVE_ENABLED, enabled).apply()
    }

    fun getOverlayY(context: Context, defaultY: Int): Int {
        val sp = prefs(context)
        return if (sp.contains(KEY_OVERLAY_Y_PX)) sp.getInt(KEY_OVERLAY_Y_PX, defaultY) else defaultY
    }

    fun saveOverlayY(context: Context, y: Int) {
        prefs(context).edit().putInt(KEY_OVERLAY_Y_PX, y).apply()
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

    fun removePendingEvent(context: Context, eventId: String) {
        synchronized(lock) {
            val sp = prefs(context)
            val arr = try {
                JSONArray(sp.getString(KEY_PENDING_EVENTS, "[]") ?: "[]")
            } catch (_: Exception) {
                return
            }
            val next = JSONArray()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                if (item.optString("eventId") != eventId) {
                    next.put(item)
                }
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

    fun addPendingCancelEventId(context: Context, eventId: String) {
        synchronized(lock) {
            val sp = prefs(context)
            val arr = try {
                JSONArray(sp.getString(KEY_PENDING_CANCEL_IDS, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            for (i in 0 until arr.length()) {
                if (arr.optString(i) == eventId) return
            }
            arr.put(eventId)
            sp.edit().putString(KEY_PENDING_CANCEL_IDS, arr.toString()).apply()
        }
    }

    fun drainPendingCancelEventIds(context: Context): List<String> {
        synchronized(lock) {
            val sp = prefs(context)
            val raw = sp.getString(KEY_PENDING_CANCEL_IDS, "[]") ?: "[]"
            sp.edit().putString(KEY_PENDING_CANCEL_IDS, "[]").apply()
            val result = mutableListOf<String>()
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val id = arr.optString(i)
                    if (id.isNotEmpty()) result.add(id)
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
