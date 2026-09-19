document.addEventListener('DOMContentLoaded', () => {
  const revealItems = document.querySelectorAll('.reveal');

  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('revealed');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12 });

    revealItems.forEach((item) => observer.observe(item));
  } else {
    revealItems.forEach((item) => item.classList.add('revealed'));
  }

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const text = button.getAttribute('data-copy');
      const label = button.querySelector('.copy-label');
      if (!text || !label) return;

      try {
        await navigator.clipboard.writeText(text);
        const original = label.textContent;
        label.textContent = 'Copied';
        window.setTimeout(() => { label.textContent = original; }, 1600);
      } catch {
        label.textContent = 'Select';
        window.setTimeout(() => { label.textContent = 'Copy'; }, 1600);
      }
    });
  });

  document.querySelectorAll('.seg-item').forEach((item) => {
    item.addEventListener('click', () => {
      document.querySelectorAll('.seg-item').forEach((segment) => segment.classList.remove('active'));
      item.classList.add('active');
    });
  });
});
