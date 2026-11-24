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

/// 主壳（三断点响应式）：
/// - Compact (< 600dp): 极简细分割底栏 + 悬浮磨砂迷你播放条；
/// - Medium (600–1024dp): 左侧精简 NavigationRail + 悬浮胶囊播放条；
/// - Expanded (> 1024dp): 左侧 DesktopSidebar + 可选右侧笔记抽屉 + 底部桌面播控台。
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
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);

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

          // 2. 平板中屏模式 (600–1024dp)
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
                      backgroundColor: tokens.surfaceElevated,
                      indicatorColor: tokens.primary.withValues(alpha: 0.16),
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.auto_stories_outlined),
                          selectedIcon: Icon(Icons.auto_stories),
                          label: Text('书架'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.search_rounded),
                          selectedIcon: Icon(Icons.manage_search_rounded),
                          label: Text('发现'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.checklist_rounded),
                          selectedIcon: Icon(Icons.checklist_rtl_rounded),
                          label: Text('任务'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.person_outline_rounded),
                          selectedIcon: Icon(Icons.person_rounded),
                          label: Text('我的'),
                        ),
                      ],
                    ),
                    VerticalDivider(width: 1, thickness: 0.6, color: hairline),
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

          // 3. 手机紧凑模式 (< 600dp)：细顶线极简底栏 + 悬浮迷你播控条
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
            bottomNavigationBar: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceElevated,
                border: Border(top: BorderSide(color: hairline, width: 0.6)),
              ),
              child: NavigationBar(
                key: const Key('echo_nav_bar'),
                selectedIndex: _currentIndex,
                height: 62,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                indicatorColor: tokens.primary.withValues(alpha: 0.14),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: select,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.auto_stories_outlined),
                    selectedIcon: Icon(Icons.auto_stories),
                    label: '书架',
                    tooltip: '书架',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search_rounded),
                    selectedIcon: Icon(Icons.manage_search_rounded),
                    label: '发现',
                    tooltip: '发现',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.checklist_rounded),
                    selectedIcon: Icon(Icons.checklist_rtl_rounded),
                    label: '任务',
                    tooltip: '任务',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: '我的',
                    tooltip: '我的',
                  ),
                ],
              ),
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
