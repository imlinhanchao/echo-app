/// 测试夹具：与 assets/design-tokens.json 的 light/dark 段一一对应。
/// 用于验证 Token 解析与主题构建，不依赖资产 I/O 的用例使用此处常量。
const Map<String, dynamic> darkColors = <String, dynamic>{
  'primary': {'base': '#D4AE74', 'hover': '#E2C28F', 'active': '#B89055'},
  'accent': {'base': '#B08B5A'},
  'surface': {'base': '#0D0E10', 'elevated': '#16171B', 'subtle': '#24262B'},
  'text': {
    'primary': '#F3EFE8',
    'secondary': '#9E9890',
    'disabled': '#5E5A54',
    'on-primary': '#14120F',
  },
  'status': {'success': '#6CC08E', 'error': '#E07373', 'warning': '#E0B462'},
  'focus': {'ring': '#D4AE74'},
  'reading': {
    'highlight-sentence': 'rgba(212, 174, 116, 0.20)',
    'paper-warm': '#12110F',
    'paper-text': '#EAE4D8',
  },
};

const Map<String, dynamic> lightColors = <String, dynamic>{
  'primary': {'base': '#8F6836', 'hover': '#7A572C', 'active': '#634622'},
  'accent': {'base': '#A67C46'},
  'surface': {'base': '#F8F5F0', 'elevated': '#FFFFFF', 'subtle': '#E8E2D9'},
  'text': {
    'primary': '#181613',
    'secondary': '#6B655D',
    'disabled': '#A59E94',
    'on-primary': '#FDFBF7',
  },
  'status': {'success': '#2E7D52', 'error': '#C2413B', 'warning': '#B87B22'},
  'focus': {'ring': '#8F6836'},
  // 注意：light 模式无 reading 节，验证降级默认值。
};
