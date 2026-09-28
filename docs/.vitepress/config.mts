import { defineConfig } from 'vitepress';
import pkg from '../package.json';

export default defineConfig({
  title: 'zap',
  description: 'A minimalist, zero-allocation shell prompt written in Zig',
  base: '/zap/',
  cleanUrls: true,

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/zap/favicon.svg' }],
    ['link', { rel: 'alternate icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    ['link', { rel: 'stylesheet', href: 'https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/symbols-nerd-font.css' }],
    ['link', { rel: 'stylesheet', href: 'https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/jetbrainsmono.css' }],
    ['meta', { name: 'theme-color', content: '#bd93f9' }]
  ],

  themeConfig: {
    siteTitle: 'zap',
    logo: '/favicon.svg',

    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Configuration', link: '/guide/configuration' },
      { text: 'Modules', link: '/config/directory' },
      {
        text: `v${pkg.version}`,
        items: [
          { text: 'Releases & Changelog', link: 'https://github.com/luth9r/zap/releases' },
          { text: 'GitHub Repository', link: 'https://github.com/luth9r/zap' }
        ]
      }
    ],

    sidebar: [
      {
        text: 'Getting Started',
        collapsed: false,
        items: [
          { text: 'Installation & Setup', link: '/guide/getting-started' },
          { text: 'Configuration', link: '/guide/configuration' },
          { text: 'Styling & Colors', link: '/guide/styling' },
          { text: 'Template Engine', link: '/guide/templates' }
        ]
      },
      {
        text: 'Modules',
        collapsed: false,
        items: [
          { text: 'directory', link: '/config/directory' },
          { text: 'git_branch', link: '/config/git-branch' },
          { text: 'git_commit', link: '/config/git-commit' },
          { text: 'git_state', link: '/config/git-state' },
          { text: 'git_status', link: '/config/git-status' },
          { text: 'cmd_duration', link: '/config/cmd-duration' },
          { text: 'character', link: '/config/character' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/luth9r/zap' }
    ],

    search: {
      provider: 'local'
    },

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © 2026 luth9r'
    }
  }
});
