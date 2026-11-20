import 'package:flutter/material.dart';

import '../../core/api/models.dart';
import '../jobs/jobs_page.dart';
import '../library/bookshelf_tab.dart';
import '../player/player_sheet.dart' show MiniPlayerBar;
import '../profile/profile_page.dart';
import '../search/search_page.dart';

/// 已登录主壳：4-Tab 导航（书架 / 发现 / 任务 / 我的）+ 底部常驻迷你播放条。
///
/// Tab 懒构建：首次访问才实例化——任务页的轮询因此只在页面可见时开启；
/// 底部迷你条点击展开 v3 播放器（PlayerSheet）。
class EchoShell extends StatefulWidget {
  const EchoShell({super.key, required this.user});

  final EchoUser user;

  @override
  State<EchoShell> createState() => _EchoShellState();
}

class _EchoShellState extends State<EchoShell> {
  int _currentIndex = 0;
  final Set<int> _visitedTabs = <int>{0};

  @override
  Widget build(BuildContext context) {
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
          const MiniPlayerBar(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: const Key('echo_nav_bar'),
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() {
          _currentIndex = index;
          _visitedTabs.add(index);
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.manage_search),
            label: '发现',
          ),
          NavigationDestination(
            icon: Icon(Icons.work_history_outlined),
            selectedIcon: Icon(Icons.work_history),
            label: '任务',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
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
