package org.hancel.echo

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        ensurePlaybackChannel()
        super.onCreate(savedInstanceState)
    }

    /**
     * 预先创建播放通知渠道（必须在 audio_service 初始化之前）。
     *
     * audio_service 默认用 IMPORTANCE_LOW 建渠道，而华为/荣耀等 ROM 会把低重要性
     * 通知排除在锁屏之外，表现为「锁屏没有任何播放控件、通知折叠态看不到封面与按钮」。
     * 渠道一旦创建，其重要性不可再改，因此这里先以 DEFAULT + 锁屏可见(PUBLIC) 建好，
     * audio_service 后续只是复用同一渠道。
     */
    private fun ensurePlaybackChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val id = "org.hancel.echo.playback"
        if (manager.getNotificationChannel(id) != null) return

        val channel = NotificationChannel(
            id,
            "Echo 播放",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "播放控制、锁屏与通知栏媒体卡片"
            setShowBadge(false)
            // 媒体播放渠道不需要声音与震动
            setSound(null, null)
            enableVibration(false)
            setLockscreenVisibility(android.app.Notification.VISIBILITY_PUBLIC)
            setShowBadge(false)
            // 关键：让系统按媒体通知对待（部分 ROM 依此决定是否显示锁屏卡片）
            setBypassDnd(false)
        }
        manager.createNotificationChannel(channel)
    }
}
