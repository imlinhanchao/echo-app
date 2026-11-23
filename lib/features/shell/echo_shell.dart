import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/sync/progress_sync_service.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_breakpoints.dart';
import '../../design/echo_tokens.dart';
import '../jobs/jobs_page.dart';
import '../library/bookshelf_tab.dart';
import '../notes/desktop_notes_drawer.dart';
import '../player/desktop_player_bar.dart';
import '../player/live_tts_mini_bar.dart';
import '../player/player_sheet.dart'
    show MiniPlayerBar, TabletCapsulePlayerBar;
import '../profile/profile_page.dart';
import '../search/search_page.dart';
import 'desktop_shortcuts.dart';
import 'desktop_sidebar.dart';

/// 已登录主壳（对齐设计规划 §2.1 三断点响应式与 §4 界面规范）：
/// - Compact (< 600dp): 底部纯图标导航 + Stack 悬浮磨砂迷你播放条（列表从背后透出模糊）；
/// - Medium (600–1024dp): 左侧 NavigationRail + Stack 悬浮胶囊播放条（含快捷打点）；
/// - Expanded (> 1024dp): 左侧完整 DesktopSidebar + 右侧笔记抽屉 + 底部全宽专业播控台。
class EchoShell extends ConsumerStatefulWidget {
  const EchoShell({super.key, required this.user});

  final EchoUser user;

  static final GlobalKey<EchoShellState> shellKey = GlobalKey<EchoShellState>();

  /// 供子页面跳转 Tab（如书架搜索入口 → 发现）。
  static void switchTab(BuildContext context, int index) {
    shellKey.currentState?.select(index);
  }

  @override
  ConsumerState<EchoShell> createState() => EchoShellState();
}

class EchoShellState extends ConsumerState<EchoShell> {
  int _currentIndex = 0;
  final Set<int> _visitedTabs = <int>{0};
  bool _isNotesOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(progressSyncServiceProvider.notifier).syncAll();
    });
  }

  void select(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  void toggleNotes() {
    setState(() {
      _isNotesOpen = !_isNotesOpen;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;

    return DesktopShortcutsWrapper(
      onAddNotePrompt: () {
        setState(() => _isNotesOpen = true);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenType = screenTypeForWidth(constraints.maxWidth);

          Widget contentStack() => IndexedStack(
            index: _currentIndex,
            children: [
              for (var i = 0; i < 4; i++)
                if (_visitedTabs.contains(i) || i == _currentIndex)
                  _buildTab(i, i == _currentIndex)
                else
                  const SizedBox.shrink(key: Key('echo_tab_placeholder')),
            ],
          );

          // 1. 桌面宽屏模式 (> 1024dp)
          if (screenType == EchoScreenType.expanded) {
            return Scaffold(
              key: const Key('echo_home'),
              body: EchoAmbientBackground(
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          DesktopSidebar(
                            user: widget.user,
                            selectedIndex: _currentIndex,
                            onSelect: select,
                          ),
                          Expanded(
                            child: SafeArea(
                              top: true,
                              bottom: false,
                              child: contentStack(),
                            ),
                          ),
                          if (_isNotesOpen)
                            DesktopNotesDrawer(
                              onClose: () =>
                                  setState(() => _isNotesOpen = false),
                            ),
                        ],
                      ),
                    ),
                    DesktopPlayerBar(
                      onToggleNotes: toggleNotes,
                      isNotesOpen: _isNotesOpen,
                    ),
                  ],
                ),
              ),
            );
          }

          // 2. 平板中屏模式 (600–1024dp)：Stack 悬浮胶囊播放条，列表滚过背后产生真磨砂
          if (screenType == EchoScreenType.medium) {
            return Scaffold(
              key: const Key('echo_home'),
              body: EchoAmbientBackground(
                child: Row(
                  children: [
                    NavigationRail(
                      key: const Key('echo_nav_rail'),
                      selectedIndex: _currentIndex,
                      onDestinationSelected: select,
                      labelType: NavigationRailLabelType.all,
                      backgroundColor: Colors.transparent,
                      indicatorColor: tokens.primary.withValues(alpha: 0.18),
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home),
                          label: Text('书架'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.search),
                          selectedIcon: Icon(Icons.manage_search),
                          label: Text('发现'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.grid_view_outlined),
                          selectedIcon: Icon(Icons.grid_view),
                          label: Text('任务'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.person_outline),
                          selectedIcon: Icon(Icons.person),
                          label: Text('我的'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: SafeArea(
                              top: true,
                              bottom: false,
                              child: contentStack(),
                            ),
                          ),
                          const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: TabletCapsulePlayerBar(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // 3. 手机紧凑模式 (< 600dp)：Stack 悬浮玻璃拟态迷你播放条
          return Scaffold(
            key: const Key('echo_home'),
            body: EchoAmbientBackground(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: SafeArea(
                      top: true,
                      bottom: false,
                      child: contentStack(),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LiveTtsMiniBar(),
                        MiniPlayerBar(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              key: const Key('echo_nav_bar'),
              selectedIndex: _currentIndex,
              height: 64,
              backgroundColor: tokens.surfaceBase,
              surfaceTintColor: Colors.transparent,
              indicatorColor: tokens.primary.withValues(alpha: 0.18),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              onDestinationSelected: select,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '书架',
                  tooltip: '书架',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  selectedIcon: Icon(Icons.manage_search),
                  label: '发现',
                  tooltip: '发现',
                ),
                NavigationDestination(
                  icon: Icon(Icons.grid_view_outlined),
                  selectedIcon: Icon(Icons.grid_view),
                  label: '任务',
                  tooltip: '任务',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的',
                  tooltip: '我的',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTab(int index, bool isActive) => switch (index) {
    0 => const BookshelfTab(),
    1 => const SearchPage(),
    2 => JobsPage(isActive: isActive),
    _ => ProfilePage(user: widget.user),
  };
}

/// 让书架等子页面能读取当前壳实例，无需层层传参。
extension EchoShellSwitch on BuildContext {
  void switchEchoTab(int index) => EchoShell.switchTab(this, index);
}
