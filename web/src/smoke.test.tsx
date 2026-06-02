/** Render smoke tests: catch render-time crashes in the UI tree. */
import { describe, it, expect } from 'vitest';
import { renderToString } from 'react-dom/server';
import App from './App';
import Playground from './playground/Playground';
import Chart from './components/Chart';
import { CHARTS } from './data/eval';

describe('UI renders without throwing', () => {
  it('renders the full App', () => {
    const html = renderToString(<App />);
    expect(html).toContain('Tiara');
    expect(html).toContain('Indirection Wall');
  });
  it('renders the Playground', () => {
    const html = renderToString(<Playground />);
    expect(html.length).toBeGreaterThan(100);
  });
  it('renders every eval chart', () => {
    for (const c of CHARTS) {
      const html = renderToString(<Chart spec={c} />);
      expect(html).toContain('svg');
    }
  });
});
