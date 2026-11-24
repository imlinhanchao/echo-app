package com.ryanheise.audioservice;

import android.app.Service;
import androidx.core.app.ServiceCompat;

/**
 * 桥接类：允许应用在显式 stop() 时让处于前台保活状态的 [AudioService]
 * 立即退出前台并移除媒体通知栏卡片（解决 STOP_FOREGROUND_DETACH 下 cancel 无效问题）。
 *
 * 通过 Object 中转转成 [Service]，避免 :app 编译期因 audio_service 使用
 * implementation("androidx.media:media") 而缺少 MediaBrowserServiceCompat 父类声明。
 */
public final class EchoAudioServiceBridge {
    private EchoAudioServiceBridge() {}

    public static void stopForegroundAndRemoveNotification() {
        final Object rawService = AudioService.instance;
        if (rawService instanceof Service) {
            ServiceCompat.stopForeground(
                (Service) rawService,
                ServiceCompat.STOP_FOREGROUND_REMOVE
            );
        }
    }
}
