# Supabase Migration Tool - UI Design System

## 🎨 Design System Overview

This document outlines the comprehensive design system used in the Supabase Migration Tool web interface, built with Tailwind CSS and modern UI/UX principles.

---

## 1. Color Palette

### Primary Colors (Indigo)
- **Primary-50**: `#f0f4ff` - Lightest background
- **Primary-100**: `#e0e9ff` - Light background
- **Primary-500**: `#6366f1` - Main brand color
- **Primary-600**: `#4f46e5` - Primary buttons, links
- **Primary-700**: `#4338ca` - Hover states
- **Primary-900**: `#312e81` - Darkest shade

**Usage**: Main actions, buttons, links, active states, brand elements

### Semantic Colors

#### Success (Green)
- **Success-50**: `#f0fdf4`
- **Success-500**: `#22c55e`
- **Success-600**: `#16a34a`
- **Usage**: Success messages, completed states, positive actions

#### Warning (Amber)
- **Warning-50**: `#fffbeb`
- **Warning-500**: `#f59e0b`
- **Warning-600**: `#d97706`
- **Usage**: Warnings, caution messages, pending states

#### Error (Red)
- **Error-50**: `#fef2f2`
- **Error-500**: `#ef4444`
- **Error-600**: `#dc2626`
- **Usage**: Error messages, failed states, destructive actions

### Neutral Colors (Slate)
- **Slate-50**: `#f8fafc` - Lightest background
- **Slate-100**: `#f1f5f9` - Light background
- **Slate-200**: `#e2e8f0` - Borders, dividers
- **Slate-500**: `#64748b` - Secondary text
- **Slate-600**: `#475569` - Body text
- **Slate-700**: `#334155` - Headings
- **Slate-900**: `#0f172a` - Darkest text

---

## 2. Typography

### Font Family
- **Primary**: `Inter` (Google Fonts)
- **Fallback**: `system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif`
- **Monospace**: `JetBrains Mono, 'Fira Code', Monaco, 'Courier New', monospace` (for logs)

### Type Scale
- **H1**: `text-2xl` (24px) - Page titles
- **H2**: `text-xl` (20px) - Section headers
- **H3**: `text-lg` (18px) - Card titles
- **Body**: `text-base` (16px) - Default text
- **Small**: `text-sm` (14px) - Secondary text, labels
- **XS**: `text-xs` (12px) - Captions, badges

### Font Weights
- **Light**: `font-light` (300)
- **Normal**: `font-normal` (400) - Body text
- **Medium**: `font-medium` (500) - Labels
- **Semibold**: `font-semibold` (600) - Headings, buttons
- **Bold**: `font-bold` (700) - Emphasis

### Line Heights
- Default: `leading-normal` (1.5)
- Tight: `leading-tight` (1.25) - Headings
- Relaxed: `leading-relaxed` (1.75) - Body text

---

## 3. Spacing & Layout

### Spacing Scale (Tailwind Default)
- **Base Unit**: 4px (0.25rem)
- **Scale**: 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96

### Common Spacing Patterns
- **Card Padding**: `p-6` or `p-8` (24px/32px)
- **Section Gap**: `space-y-6` (24px vertical)
- **Grid Gap**: `gap-6` (24px)
- **Button Padding**: `px-4 py-2` or `px-8 py-3.5`
- **Input Padding**: `px-4 py-3` (16px horizontal, 12px vertical)

### Container
- **Max Width**: `max-w-7xl` (1280px)
- **Padding**: `px-4 sm:px-6 lg:px-8` (responsive)

---

## 4. Components

### Buttons

#### Primary Button
```html
<button class="px-8 py-3.5 bg-gradient-to-r from-primary-600 to-primary-700 text-white font-semibold rounded-xl shadow-lg shadow-primary-500/25 hover:shadow-xl hover:shadow-primary-500/30 hover:from-primary-700 hover:to-primary-800 transform hover:-translate-y-0.5 transition-all duration-200">
    Button Text
</button>
```

**States**:
- **Default**: Gradient background, shadow, rounded corners
- **Hover**: Darker gradient, larger shadow, slight lift
- **Focus**: Ring outline for accessibility
- **Disabled**: Reduced opacity, no interaction

#### Secondary Button
```html
<button class="px-4 py-2 bg-primary-600 text-white text-sm font-semibold rounded-lg hover:bg-primary-700 shadow-md hover:shadow-lg transition-all duration-200">
    Button Text
</button>
```

### Cards

#### Standard Card
```html
<div class="bg-white/80 backdrop-blur-sm rounded-2xl shadow-xl border border-slate-200/60 p-8">
    <!-- Card content -->
</div>
```

**Features**:
- Semi-transparent white background with backdrop blur
- Rounded corners (`rounded-2xl`)
- Shadow for depth
- Subtle border

### Form Inputs

#### Text Input / Select
```html
<input class="w-full px-4 py-3 bg-white border-2 border-slate-200 rounded-xl text-slate-900 focus:border-primary-500 focus:ring-2 focus:ring-primary-200 transition-all duration-200" />
```

**States**:
- **Default**: White background, slate border
- **Focus**: Primary border, ring highlight
- **Error**: Error border color (if needed)

### Checkboxes

#### Custom Checkbox Label
```html
<label class="flex items-center space-x-3 p-4 bg-slate-50 rounded-xl border-2 border-slate-200 hover:border-primary-300 hover:bg-primary-50/50 cursor-pointer transition-all duration-200">
    <input type="checkbox" class="w-5 h-5 text-primary-600 border-slate-300 rounded focus:ring-2 focus:ring-primary-500 focus:ring-offset-2">
    <div>
        <span class="font-medium text-slate-900">Label</span>
        <p class="text-xs text-slate-500">Description</p>
    </div>
</label>
```

### Alerts / Notifications

#### Success Alert
```html
<div class="flex items-start space-x-3 p-4 rounded-xl border-2 bg-success-50 border-success-200 text-success-800">
    <svg class="w-5 h-5 text-success-600">...</svg>
    <div>Message</div>
</div>
```

#### Error Alert
```html
<div class="flex items-start space-x-3 p-4 rounded-xl border-2 bg-error-50 border-error-200 text-error-800">
    <svg class="w-5 h-5 text-error-600">...</svg>
    <div>Message</div>
</div>
```

### Log Container

#### Terminal-Style Log Display
```html
<div class="log-container bg-slate-900 rounded-xl p-6 max-h-96 overflow-y-auto custom-scrollbar">
    <div class="font-mono text-sm mb-1 text-slate-300">Log line</div>
    <div class="font-mono text-sm mb-1 text-success-400">Success line</div>
    <div class="font-mono text-sm mb-1 text-error-400">Error line</div>
</div>
```

**Features**:
- Dark background (`bg-slate-900`)
- Monospace font
- Color-coded lines (success, error, warning)
- Custom scrollbar styling
- Auto-scroll to bottom

---

## 5. Animations & Transitions

### Transitions
- **Duration**: `duration-200` (200ms) - Standard
- **Easing**: `ease-in-out` or `ease-out`
- **Properties**: Color, background, border, transform, shadow

### Animations
- **Fade In**: `animate-fade-in` - For tab content
- **Slide Up**: `animate-slide-up` - For modals
- **Spin**: `animate-spin` - For loading spinners
- **Pulse**: `animate-pulse` - For loading states

### Hover Effects
- **Buttons**: Lift (`hover:-translate-y-0.5`), shadow increase
- **Cards**: Border color change, shadow increase
- **Links**: Color change, underline (if applicable)

---

## 6. Accessibility (A11y)

### Focus Indicators
- **Visible Focus**: `focus-visible` with ring outline
- **Ring Color**: Primary color
- **Ring Offset**: 2px

### Color Contrast
- All text meets WCAG AA standards (4.5:1 minimum)
- Error/success states use sufficient contrast
- Icons have text labels where needed

### Semantic HTML
- Proper heading hierarchy (h1 → h2 → h3)
- Form labels associated with inputs
- Button roles and states
- ARIA labels where needed

### Keyboard Navigation
- All interactive elements are keyboard accessible
- Tab order is logical
- Escape key closes modals
- Enter/Space activates buttons

---

## 7. Responsive Design

### Breakpoints (Tailwind Default)
- **sm**: 640px - Small tablets
- **md**: 768px - Tablets
- **lg**: 1024px - Laptops
- **xl**: 1280px - Desktops
- **2xl**: 1536px - Large desktops

### Responsive Patterns
- **Grid**: `grid-cols-1 md:grid-cols-2 lg:grid-cols-3`
- **Padding**: `px-4 sm:px-6 lg:px-8`
- **Text**: `text-sm md:text-base`
- **Spacing**: `space-y-4 md:space-y-6`

---

## 8. Design Principles Applied

### 1. Clarity & Simplicity
- Clean, uncluttered layouts
- Clear visual hierarchy
- Intuitive navigation
- Self-explanatory interface

### 2. Visual Hierarchy
- Size: Larger elements draw attention
- Color: Primary colors for important actions
- Contrast: High contrast for readability
- Spacing: Generous whitespace

### 3. Consistency
- Uniform spacing scale
- Consistent component styles
- Predictable interactions
- Standardized color usage

### 4. Modern Aesthetics
- Gradient backgrounds
- Backdrop blur effects
- Subtle shadows and depth
- Smooth animations
- Rounded corners

### 5. Accessibility
- High contrast ratios
- Focus indicators
- Semantic HTML
- Keyboard navigation
- Screen reader support

---

## 9. Key Design Decisions

### Why Tailwind CSS?
- **Utility-first**: Rapid development, consistent design
- **Responsive**: Built-in breakpoints
- **Customizable**: Easy to extend and theme
- **Performance**: Purged unused styles in production

### Why Gradient Backgrounds?
- **Modern**: Contemporary design trend
- **Visual Interest**: Adds depth without clutter
- **Brand Identity**: Creates memorable experience

### Why Backdrop Blur?
- **Depth**: Creates layering effect
- **Modern**: Contemporary design pattern
- **Subtle**: Doesn't distract from content

### Why Rounded Corners?
- **Friendly**: Softer, more approachable
- **Modern**: Contemporary design standard
- **Consistent**: Unified look across components

### Why Color-Coded Logs?
- **Quick Scanning**: Easy to identify issues
- **Visual Feedback**: Immediate status recognition
- **Professional**: Terminal-like appearance

---

## 10. Component Variants

### Button Variants
1. **Primary**: Gradient, large, prominent
2. **Secondary**: Solid color, medium size
3. **Ghost**: Transparent, minimal
4. **Danger**: Red, for destructive actions

### Card Variants
1. **Standard**: White background, shadow
2. **Elevated**: Stronger shadow, more prominent
3. **Outlined**: Border-focused, minimal shadow

### Alert Variants
1. **Success**: Green, for positive feedback
2. **Error**: Red, for errors
3. **Warning**: Amber, for cautions
4. **Info**: Blue, for information

---

## 11. Usage Examples

### Creating a New Button
```html
<button class="px-6 py-3 bg-primary-600 text-white font-semibold rounded-lg hover:bg-primary-700 shadow-md hover:shadow-lg transition-all duration-200">
    Click Me
</button>
```

### Creating a New Card
```html
<div class="bg-white/80 backdrop-blur-sm rounded-2xl shadow-xl border border-slate-200/60 p-6">
    <h3 class="text-lg font-bold text-slate-900 mb-4">Card Title</h3>
    <p class="text-slate-600">Card content</p>
</div>
```

### Creating a Form Input
```html
<div>
    <label class="block text-sm font-semibold text-slate-700 mb-2">Label</label>
    <input type="text" class="w-full px-4 py-3 bg-white border-2 border-slate-200 rounded-xl focus:border-primary-500 focus:ring-2 focus:ring-primary-200 transition-all duration-200" />
</div>
```

---

## 12. Future Enhancements

### Potential Additions
- Dark mode support
- Custom theme switcher
- More animation variants
- Advanced form validation styles
- Toast notification system
- Progress indicators
- Skeleton loaders

---

## Conclusion

This design system provides a solid foundation for building a modern, accessible, and visually appealing user interface. By following these guidelines, we ensure consistency, maintainability, and an excellent user experience across the entire application.

For questions or suggestions, please refer to the main project documentation or create an issue in the repository.

