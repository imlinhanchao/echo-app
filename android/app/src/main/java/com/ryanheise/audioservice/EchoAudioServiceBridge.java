package com.ryanheise.audioservice;

import androidx.core.app.ServiceCompat;

/**
 * 桥接类：允许应用在显式 stop() 时让处于前台保活状态的 [AudioService]
 * 立即退出前台并移除媒体通知栏卡片（解决 STOP_FOREGROUND_DETACH 下 cancel 无效问题）。
 */
public final class EchoAudioServiceBridge {
    private EchoAudioServiceBridge() {}

    public static void stopForegroundAndRemoveNotification() {
        final AudioService service = AudioService.instance;
        if (service != null) {
            ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE);
        }
    }
}
