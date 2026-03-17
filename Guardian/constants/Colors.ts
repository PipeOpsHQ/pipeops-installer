// Apple-style Nerdy & Rich Theme Palette
export const Colors = {
  dark: {
    background: '#000000', // True Black for OLED
    surface: '#1c1c1e',    // Apple System Background (Secondary)
    elevated: '#2c2c2e',   // Apple System Background (Tertiary)

    primary: '#0A84FF',    // Apple System Blue
    secondary: '#5E5CE6',  // Apple System Indigo
    accent: '#64D2FF',     // Apple System Cyan

    text: '#FFFFFF',
    textSecondary: '#8E8E93', // Apple System Gray (Secondary)
    textTertiary: '#48484A',  // Apple System Gray (Tertiary)

    border: '#38383A',
    separator: '#48484A',

    error: '#FF453A',      // Apple System Red
    success: '#32D74B',    // Apple System Green
    warning: '#FFD60A',    // Apple System Yellow

    glass: 'rgba(28, 28, 30, 0.7)', // For Glassmorphism
    glassBorder: 'rgba(255, 255, 255, 0.1)',
  },
};

export const Theme = Colors.dark;
