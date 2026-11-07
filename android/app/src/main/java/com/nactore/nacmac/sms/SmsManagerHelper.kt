package com.nactore.nacmac.sms

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import com.nactore.nacmac.model.SMSMessageItem
import com.nactore.nacmac.model.SMSThreadItem

object SmsManagerHelper {
    private const val TAG = "NacMac-SMS"

    fun getConversations(context: Context, limit: Int = 50): List<SMSThreadItem> {
        val threads = mutableListOf<SMSThreadItem>()
        val uri = Telephony.Sms.Conversations.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms.Conversations.THREAD_ID,
            Telephony.Sms.Conversations.SNIPPET,
            Telephony.Sms.Conversations.MESSAGE_COUNT
        )
        
        try {
            val cursor = context.contentResolver.query(
                uri,
                projection,
                null,
                null,
                null
            )
            
            cursor?.use { c ->
                val threadIdIdx = c.getColumnIndex(Telephony.Sms.Conversations.THREAD_ID)
                val snippetIdx = c.getColumnIndex(Telephony.Sms.Conversations.SNIPPET)
                
                while (c.moveToNext()) {
                    val threadId = c.getLong(threadIdIdx)
                    val snippet = if (snippetIdx != -1) c.getString(snippetIdx) ?: "" else ""
                    
                    val detail = getLatestThreadDetail(context, threadId)
                    val contactName = resolveContactName(context, detail.address)
                    
                    threads.add(
                        SMSThreadItem(
                            threadId = threadId,
                            address = detail.address,
                            contactName = contactName,
                            snippet = if (snippet.isNotEmpty()) snippet else detail.snippet,
                            timestamp = detail.timestamp,
                            unreadCount = detail.unreadCount
                        )
                    )
                    if (threads.size >= limit) break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Conversations query failed, falling back to SMS query: ${e.message}")
        }
        
        if (threads.isEmpty()) {
            threads.addAll(getConversationsFallback(context, limit))
        }
        
        return threads
    }

    private data class ThreadDetail(val address: String, val snippet: String, val timestamp: Long, val unreadCount: Int)

    private fun getLatestThreadDetail(context: Context, threadId: Long): ThreadDetail {
        var address = "Unknown"
        var snippet = ""
        var timestamp = 0L
        var unread = 0

        try {
            val cursor = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.READ),
                "${Telephony.Sms.THREAD_ID} = ?",
                arrayOf(threadId.toString()),
                "${Telephony.Sms.DATE} DESC"
            )
            cursor?.use { c ->
                if (c.moveToFirst()) {
                    val addrIdx = c.getColumnIndex(Telephony.Sms.ADDRESS)
                    val bodyIdx = c.getColumnIndex(Telephony.Sms.BODY)
                    val dateIdx = c.getColumnIndex(Telephony.Sms.DATE)
                    val readIdx = c.getColumnIndex(Telephony.Sms.READ)

                    if (addrIdx != -1) address = c.getString(addrIdx) ?: "Unknown"
                    if (bodyIdx != -1) snippet = c.getString(bodyIdx) ?: ""
                    if (dateIdx != -1) timestamp = c.getLong(dateIdx)
                    if (readIdx != -1 && c.getInt(readIdx) == 0) unread = 1
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get thread detail: ${e.message}")
        }
        return ThreadDetail(address, snippet, timestamp, unread)
    }

    private fun getConversationsFallback(context: Context, limit: Int): List<SMSThreadItem> {
        val threadMap = mutableMapOf<Long, SMSThreadItem>()
        try {
            val cursor = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.READ),
                null,
                null,
                "${Telephony.Sms.DATE} DESC"
            )
            cursor?.use { c ->
                val threadIdIdx = c.getColumnIndex(Telephony.Sms.THREAD_ID)
                val addrIdx = c.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIdx = c.getColumnIndex(Telephony.Sms.BODY)
                val dateIdx = c.getColumnIndex(Telephony.Sms.DATE)
                val readIdx = c.getColumnIndex(Telephony.Sms.READ)

                while (c.moveToNext()) {
                    val threadId = c.getLong(threadIdIdx)
                    if (!threadMap.containsKey(threadId)) {
                        val address = c.getString(addrIdx) ?: "Unknown"
                        val snippet = c.getString(bodyIdx) ?: ""
                        val date = c.getLong(dateIdx)
                        val read = c.getInt(readIdx)
                        val contactName = resolveContactName(context, address)

                        threadMap[threadId] = SMSThreadItem(
                            threadId = threadId,
                            address = address,
                            contactName = contactName,
                            snippet = snippet,
                            timestamp = date,
                            unreadCount = if (read == 0) 1 else 0
                        )
                    }
                    if (threadMap.size >= limit) break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Fallback conversations query failed: ${e.message}")
        }
        return threadMap.values.toList()
    }

    fun getMessages(context: Context, threadId: Long, limit: Int = 100): List<SMSMessageItem> {
        val messages = mutableListOf<SMSMessageItem>()
        try {
            val cursor = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
                "${Telephony.Sms.THREAD_ID} = ?",
                arrayOf(threadId.toString()),
                "${Telephony.Sms.DATE} DESC"
            )
            cursor?.use { c ->
                val idIdx = c.getColumnIndex(Telephony.Sms._ID)
                val threadIdIdx = c.getColumnIndex(Telephony.Sms.THREAD_ID)
                val addrIdx = c.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIdx = c.getColumnIndex(Telephony.Sms.BODY)
                val dateIdx = c.getColumnIndex(Telephony.Sms.DATE)
                val typeIdx = c.getColumnIndex(Telephony.Sms.TYPE)

                while (c.moveToNext()) {
                    val msgId = c.getLong(idIdx)
                    val tId = c.getLong(threadIdIdx)
                    val address = c.getString(addrIdx) ?: ""
                    val body = c.getString(bodyIdx) ?: ""
                    val date = c.getLong(dateIdx)
                    val type = c.getInt(typeIdx)
                    val isIncoming = (type == Telephony.Sms.MESSAGE_TYPE_INBOX)

                    messages.add(
                        SMSMessageItem(
                            messageId = msgId,
                            threadId = tId,
                            address = address,
                            body = body,
                            timestamp = date,
                            isIncoming = isIncoming
                        )
                    )
                    if (messages.size >= limit) break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Messages query failed: ${e.message}")
        }
        return messages.reversed()
    }

    fun sendSms(context: Context, recipient: String, message: String): Boolean {
        return try {
            val smsManager: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }

            val parts = smsManager.divideMessage(message)
            if (parts.size > 1) {
                smsManager.sendMultipartTextMessage(recipient, null, parts, null, null)
            } else {
                smsManager.sendTextMessage(recipient, null, message, null, null)
            }

            // Attempt to write sent message to system Telephony provider for history continuity
            try {
                val values = android.content.ContentValues().apply {
                    put(Telephony.Sms.ADDRESS, recipient)
                    put(Telephony.Sms.BODY, message)
                    put(Telephony.Sms.DATE, System.currentTimeMillis())
                    put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
                }
                context.contentResolver.insert(Telephony.Sms.Sent.CONTENT_URI, values)
            } catch (_: Exception) {}

            Log.i(TAG, "SMS successfully dispatched to $recipient")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send SMS to $recipient: ${e.message}")
            false
        }
    }

    private fun resolveContactName(context: Context, phoneNumber: String): String? {
        if (phoneNumber.isEmpty() || phoneNumber == "Unknown") return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(phoneNumber)
            )
            val cursor = context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )
            cursor?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }
}
