import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../../design/echo_tokens.dart';
import '../jobs/jobs_page.dart';
import '../library/bookshelf_tab.dart';
import '../player/player_sheet.dart' show MiniPlayerBar;
import '../profile/profile_page.dart';
import '../search/search_page.dart';

/// 已登录主壳（对齐设计图 ui-mobile-library）：
/// 底部纯图标导航（书架 / 发现 / 任务 / 我的）+ 悬浮胶囊迷你播放条。
///
/// Tab 懒构建：首次访问才实例化——任务页轮询因此只在可见时开启。
class EchoShell extends StatefulWidget {
  const EchoShell({super.key, required this.user});

  final EchoUser user;

  static final GlobalKey<EchoShellState> shellKey = GlobalKey<EchoShellState>();

  /// 供子页面跳转 Tab（如书架搜索入口 → 发现）。
  static void switchTab(BuildContext context, int index) {
    shellKey.currentState?.select(index);
  }

  @override
  State<EchoShell> createState() => EchoShellState();
}

class EchoShellState extends State<EchoShell> {
  int _currentIndex = 0;
  final Set<int> _visitedTabs = <int>{0};

  void select(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Scaffold(
      key: const Key('echo_home'),
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                for (var i = 0; i < 4; i++)
                  if (_visitedTabs.contains(i) || i == _currentIndex)
                    _buildTab(i)
                  else
                    const SizedBox.shrink(key: Key('echo_tab_placeholder')),
              ],
            ),
          ),
          // 悬浮胶囊迷你播放条（设计图底部）
          const MiniPlayerBar(),
        ],
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
  }

  Widget _buildTab(int index) => switch (index) {
    0 => const BookshelfTab(),
    1 => const SearchPage(),
    2 => const JobsPage(),
    _ => ProfilePage(user: widget.user),
  };
}

/// 让书架等子页面能读取当前壳实例，无需层层传参。
extension EchoShellSwitch on BuildContext {
  void switchEchoTab(int index) => EchoShell.switchTab(this, index);
}
