package com.nactore.nacmac

import com.nactore.nacmac.data.PairedMac
import com.nactore.nacmac.model.*
import com.nactore.nacmac.service.NacMacAccessibilityService
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {

    @Test
    fun testClipboardPayloadAndLoopPrevention() {
        val text = "Copy text with emojis 🚀 and newlines\nLine 2"
        val hash = NacMacAccessibilityService.computeSha256(text)
        val payload = ClipboardSyncPayload(
            text = text,
            timestamp = System.currentTimeMillis(),
            sourceDeviceId = "pixel-1234",
            hash = hash
        )
        val jsonStr = payload.toJSON().toString()
        val decoded = ClipboardSyncPayload.fromJSON(jsonStr)

        assertNotNull(decoded)
        assertEquals(text, decoded!!.text)
        assertEquals(hash, decoded.hash)
        assertEquals("pixel-1234", decoded.sourceDeviceId)

        // Verify SHA-256 computation matches
        assertEquals(hash, NacMacAccessibilityService.computeSha256(decoded.text))
    }

    @Test
    fun testNotificationPayloadWithActionsAndReply() {
        val actions = listOf(
            NotificationActionInfo(index = 0, title = "Reply", isReply = true, supportsReply = true),
            NotificationActionInfo(index = 1, title = "Mark Read", isReply = false, supportsReply = false)
        )
        val payload = NotificationPayload(
            id = "pkg_123_0",
            packageName = "com.whatsapp",
            appName = "WhatsApp",
            title = "Alex",
            body = "Hello NacMac",
            hasReplyAction = true,
            supportsReply = true,
            deviceId = "pixel-1234",
            deviceName = "Google Pixel 8",
            actions = actions
        )

        val jsonStr = payload.toJSON().toString()
        val decoded = NotificationPayload.fromJSON(jsonStr)

        assertNotNull(decoded)
        assertEquals("pkg_123_0", decoded!!.id)
        assertTrue(decoded.hasReplyAction)
        assertTrue(decoded.supportsReply)
        assertEquals(2, decoded.actions.size)
        assertTrue(decoded.actions[0].isReply)
        assertTrue(decoded.actions[0].supportsReply)
        assertEquals("Reply", decoded.actions[0].title)
        assertFalse(decoded.actions[1].isReply)
        assertFalse(decoded.actions[1].supportsReply)
    }

    @Test
    fun testSmsPayloads() {
        val threads = listOf(
            SMSThreadItem(
                threadId = 42L,
                address = "+1234567890",
                contactName = "John Doe",
                snippet = "See you tomorrow",
                timestamp = 1700000000000L,
                unreadCount = 1
            )
        )
        val resp = SMSConversationsResponsePayload(threads = threads, deviceId = "phone-abc")
        val jsonStr = resp.toJSON().toString()
        val decoded = SMSConversationsResponsePayload.fromJSON(jsonStr)

        assertNotNull(decoded)
        assertEquals(1, decoded!!.threads.size)
        assertEquals(42L, decoded.threads[0].threadId)
        assertEquals("John Doe", decoded.threads[0].contactName)
        assertEquals("phone-abc", decoded.deviceId)

        val sendReq = SMSSendPayload(recipient = "+1234567890", message = "Hi!", threadId = 42L, deviceId = "phone-abc")
        val sendJson = sendReq.toJSON().toString()
        val decodedSend = SMSSendPayload.fromJSON(sendJson)

        assertNotNull(decodedSend)
        assertEquals("+1234567890", decodedSend!!.recipient)
        assertEquals("Hi!", decodedSend.message)
        assertEquals(42L, decodedSend.threadId)
    }

    @Test
    fun testPairedMacSerialization() {
        val mac = PairedMac(
            macId = "mac-uuid-001",
            macName = "Ayush's MacBook Air",
            lastKnownIp = "192.168.1.150",
            port = 52840,
            secret = "SECRET123"
        )
        val json = mac.toJSON()
        val decoded = PairedMac.fromJSON(json)

        assertEquals("mac-uuid-001", decoded.macId)
        assertEquals("Ayush's MacBook Air", decoded.macName)
        assertEquals("192.168.1.150", decoded.lastKnownIp)
        assertEquals(52840, decoded.port)
        assertEquals("SECRET123", decoded.secret)
    }
}
