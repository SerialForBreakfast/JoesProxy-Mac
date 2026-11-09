//
// JoesProxy.com — Main Client Script
//

document.addEventListener('DOMContentLoaded', () => {
  initThemeToggle();
  initCopyButtons();
  initTabs();
  initFilterSearch();
});

// Theme Management
function initThemeToggle() {
  const toggleBtn = document.querySelector('[data-theme-toggle]');
  if (!toggleBtn) return;

  const currentTheme = localStorage.getItem('theme') || 
    (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  
  document.documentElement.setAttribute('data-theme', currentTheme);

  toggleBtn.addEventListener('click', () => {
    const activeTheme = document.documentElement.getAttribute('data-theme') || 'light';
    const nextTheme = activeTheme === 'dark' ? 'light' : 'dark';
    
    document.documentElement.setAttribute('data-theme', nextTheme);
    localStorage.setItem('theme', nextTheme);
  });
}

// Copy to Clipboard Buttons
function initCopyButtons() {
  document.querySelectorAll('[data-copy]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const targetId = btn.getAttribute('data-copy');
      const targetEl = document.getElementById(targetId);
      const textToCopy = targetEl ? targetEl.innerText : btn.getAttribute('data-copy-text');

      if (textToCopy) {
        try {
          await navigator.clipboard.writeText(textToCopy.trim());
          const originalText = btn.innerText;
          btn.innerText = 'Copied!';
          setTimeout(() => {
            btn.innerText = originalText;
          }, 2000);
        } catch (err) {
          console.error('Failed to copy text', err);
        }
      }
    });
  });
}

// Tab Switching
function initTabs() {
  document.querySelectorAll('[data-tabs]').forEach(tabContainer => {
    const tabButtons = tabContainer.querySelectorAll('[data-tab-target]');
    const tabPanels = tabContainer.querySelectorAll('[data-tab-panel]');

    tabButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const target = btn.getAttribute('data-tab-target');

        tabButtons.forEach(b => b.classList.remove('active'));
        tabPanels.forEach(p => p.classList.remove('active'));

        btn.classList.add('active');
        const activePanel = tabContainer.querySelector(`[data-tab-panel="${target}"]`);
        if (activePanel) {
          activePanel.classList.add('active');
        }
      });
    });
  });
}

// Search / Filter Input
function initFilterSearch() {
  const searchInput = document.querySelector('[data-search-input]');
  if (!searchInput) return;

  const searchableItems = document.querySelectorAll('[data-searchable]');
  searchInput.addEventListener('input', () => {
    const query = searchInput.value.toLowerCase().trim();

    searchableItems.forEach(item => {
      const text = item.innerText.toLowerCase();
      if (!query || text.includes(query)) {
        item.style.display = '';
      } else {
        item.style.display = 'none';
      }
    });
  });
}
