/// 测试夹具：与 assets/design-tokens.json 的 light/dark 段一一对应。
/// 用于验证 Token 解析与主题构建，不依赖资产 I/O 的用例使用此处常量。
const Map<String, dynamic> darkColors = <String, dynamic>{
  'primary': {'base': '#6366F1', 'hover': '#818CF8', 'active': '#4F46E5'},
  'accent': {'base': '#FB923C'},
  'surface': {'base': '#020617', 'elevated': '#0F172A', 'subtle': '#1E293B'},
  'text': {
    'primary': '#F1F5F9',
    'secondary': '#94A3B8',
    'disabled': '#475569',
    'on-primary': '#FFFFFF',
  },
  'status': {'success': '#4ADE80', 'error': '#F87171', 'warning': '#FBBF24'},
  'focus': {'ring': '#818CF8'},
  'reading': {
    'highlight-sentence': 'rgba(99, 102, 241, 0.24)',
    'paper-warm': '#0B1220',
    'paper-text': '#E8E3D8',
  },
};

const Map<String, dynamic> lightColors = <String, dynamic>{
  'primary': {'base': '#4F46E5', 'hover': '#4338CA', 'active': '#3730A3'},
  'accent': {'base': '#F97316'},
  'surface': {'base': '#F8FAFC', 'elevated': '#FFFFFF', 'subtle': '#E2E8F0'},
  'text': {
    'primary': '#0F172A',
    'secondary': '#475569',
    'disabled': '#94A3B8',
    'on-primary': '#FFFFFF',
  },
  'status': {'success': '#16A34A', 'error': '#DC2626', 'warning': '#D97706'},
  'focus': {'ring': '#4F46E5'},
  // 注意：light 模式无 reading 节，验证降级默认值。
};
