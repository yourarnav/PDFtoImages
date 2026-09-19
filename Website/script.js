document.addEventListener('DOMContentLoaded', () => {
  // Reveal on scroll
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('revealed');
      }
    });
  }, { threshold: 0.12 });

  document.querySelectorAll('.reveal').forEach((el) => observer.observe(el));

  // Copy to clipboard
  const copyButtons = document.querySelectorAll('[data-copy]');
  copyButtons.forEach((btn) => {
    btn.addEventListener('click', async () => {
      const textToCopy = btn.getAttribute('data-copy');
      if (!textToCopy) return;

      try {
        await navigator.clipboard.writeText(textToCopy);
        const labelEl = btn.querySelector('.copy-label') || btn;
        const originalText = labelEl.textContent;
        labelEl.textContent = 'Copied!';
        btn.classList.add('copied');

        setTimeout(() => {
          labelEl.textContent = originalText;
          btn.classList.remove('copied');
        }, 2000);
      } catch (err) {
        console.error('Failed to copy: ', err);
      }
    });
  });

  // Segmented control mockup interactivity
  const segItems = document.querySelectorAll('.seg-item');
  segItems.forEach((item) => {
    item.addEventListener('click', () => {
      segItems.forEach((s) => s.classList.remove('active'));
      item.classList.add('active');
    });
  });
});
