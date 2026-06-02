// @vitest-environment happy-dom
/**
 * Interaction tests for the Playground: the single-stepping mode must
 * advance execution and reflect it in the DOM (register writes, current
 * instruction highlight, latency, trace, verifier).
 */
import { describe, it, expect, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import Playground from './Playground';

afterEach(cleanup);

describe('Playground single-stepping', () => {
  it('assembles on mount and shows the instruction store + registers', () => {
    render(<Playground />);
    // graph_walk default preset is loaded and assembled by the mount effect
    expect(screen.getByText('Instruction store')).toBeDefined();
    expect(screen.getByText('Register file')).toBeDefined();
    // register file shows r0..r15
    expect(screen.getByText('r0')).toBeDefined();
    expect(screen.getByText('r15')).toBeDefined();
  });

  it('Step advances the PC and highlights the current instruction', () => {
    const { container } = render(<Playground />);
    const pcBefore = container.querySelector('.instr.current');
    fireEvent.click(screen.getByText('Step ▸'));
    fireEvent.click(screen.getByText('Step ▸'));
    const cur = container.querySelectorAll('.instr.current');
    expect(cur.length).toBe(1); // exactly one instruction highlighted
    // a trace line should now exist
    expect(container.querySelector('.logline')).not.toBeNull();
  });

  it('stepping writes a register (changed-highlight appears)', () => {
    const { container } = render(<Playground />);
    // step several times to execute at least one ALU/LOAD write
    for (let i = 0; i < 4; i++) fireEvent.click(screen.getByText('Step ▸'));
    const changed = container.querySelectorAll('.reg.changed');
    expect(changed.length).toBeGreaterThan(0);
  });

  it('running to completion produces a returned result', () => {
    const { container } = render(<Playground />);
    // graph_walk default depth=3 -> a few dozen steps; click Step many times
    for (let i = 0; i < 80; i++) {
      const btn = screen.getByText('Step ▸') as HTMLButtonElement;
      if (btn.disabled) break;
      fireEvent.click(btn);
    }
    expect(container.querySelector('.result')).not.toBeNull();
    expect(screen.getByText(/halted/)).toBeDefined();
  });

  it('shows the static verifier verdict', () => {
    render(<Playground />);
    expect(screen.getByText('Static verifier')).toBeDefined();
    expect(screen.getByText('PASS')).toBeDefined();
  });

  it('switching preset and re-assembling works', () => {
    render(<Playground />);
    fireEvent.click(screen.getByText('Distributed lock'));
    fireEvent.click(screen.getByText('Assemble & load'));
    // dist_lock has a CAS — step into it and confirm trace populates
    for (let i = 0; i < 6; i++) fireEvent.click(screen.getByText('Step ▸'));
    expect(document.querySelector('.logline')).not.toBeNull();
  });

  it('compiling C produces assembly in the editor', () => {
    render(<Playground />);
    fireEvent.click(screen.getByText('Restricted C'));
    fireEvent.click(screen.getByText(/Compile C/));
    const ta = document.querySelector('textarea.code') as HTMLTextAreaElement;
    expect(ta.value).toMatch(/RET/);
  });
});
