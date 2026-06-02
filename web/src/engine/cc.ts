/**
 * Tiara C compiler — restricted-C subset -> Tiara assembly.
 *
 * TypeScript port of `sw/compiler/tiara_cc.py` (paper §3.4). The Python
 * reference leans on pycparser; here we hand-roll a small lexer + a
 * recursive-descent parser for exactly the subset the compiler accepts,
 * then reproduce the same lowering (register allocation, region naming
 * convention, ANDI-masking discipline, tiara_* builtins). The emitted
 * `.tasm` is fed to the same assembler/verifier as everything else.
 *
 * Accepted subset:
 *  - one function; up to 8 args -> r1..r8; pointer args tagged with a
 *    region via the `name_in_<region>_<size>` naming convention.
 *  - uint64_t/int64_t scalar locals.
 *  - + - * & | ^ << >> == < >= ; unary - !.
 *  - p[expr] dereference (8-byte elements).
 *  - for (int i = 0; i < N; i++)  ->  LOOP rN, body.
 *  - if (cond) { ... }            ->  forward JUMP.
 *  - return expr;
 *  - builtins: tiara_andi, tiara_memcpy, tiara_cas, tiara_caa,
 *    tiara_wait, tiara_set_result.
 */

export class CompileError extends Error {
  constructor(msg: string, public line?: number) {
    super(line ? `line ${line}: ${msg}` : msg);
    this.name = 'CompileError';
  }
}

// --- lexer -----------------------------------------------------------

type TokType = 'id' | 'num' | 'punct' | 'eof';
interface Token {
  type: TokType;
  value: string;
  line: number;
}

const TYPE_KEYWORDS = new Set([
  'void',
  'int',
  'unsigned',
  'signed',
  'long',
  'char',
  'short',
  'uint64_t',
  'int64_t',
  'u64',
  'uint32_t',
]);
const KEYWORDS = new Set(['for', 'if', 'else', 'return', 'while', ...TYPE_KEYWORDS]);

// Multi-char punctuators, longest first.
const PUNCT = [
  '<<=',
  '>>=',
  '==',
  '!=',
  '<=',
  '>=',
  '<<',
  '>>',
  '&&',
  '||',
  '++',
  '--',
  '+=',
  '-=',
  '*=',
  '/=',
  '&=',
  '|=',
  '^=',
  '+',
  '-',
  '*',
  '/',
  '%',
  '&',
  '|',
  '^',
  '~',
  '!',
  '<',
  '>',
  '=',
  '(',
  ')',
  '{',
  '}',
  '[',
  ']',
  ';',
  ',',
];

function preprocess(src: string): string {
  src = src.replace(/\/\*[\s\S]*?\*\//g, ''); // block comments
  src = src.replace(/\/\/[^\n]*/g, ''); // line comments
  src = src.replace(/^[ \t]*#[^\n]*/gm, ''); // preprocessor
  for (const kw of ['__kernel', '__global', '__local', '__constant', '__private', 'kernel']) {
    src = src.replace(new RegExp(`\\b${kw}\\b`, 'g'), '');
  }
  src = src.replace(/^\s*typedef\b[^;]*;\s*$/gm, ''); // drop typedefs
  return src;
}

function lex(src: string): Token[] {
  const toks: Token[] = [];
  let i = 0;
  let line = 1;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '\n') {
      line++;
      i++;
      continue;
    }
    if (/\s/.test(c)) {
      i++;
      continue;
    }
    // number
    if (/[0-9]/.test(c)) {
      let j = i + 1;
      if (c === '0' && (src[j] === 'x' || src[j] === 'X')) {
        j++;
        while (j < n && /[0-9a-fA-F_]/.test(src[j])) j++;
      } else if (c === '0' && (src[j] === 'b' || src[j] === 'B')) {
        j++;
        while (j < n && /[01_]/.test(src[j])) j++;
      } else {
        while (j < n && /[0-9_]/.test(src[j])) j++;
      }
      while (j < n && /[uUlL]/.test(src[j])) j++; // suffixes
      toks.push({ type: 'num', value: src.slice(i, j), line });
      i = j;
      continue;
    }
    // identifier
    if (/[A-Za-z_]/.test(c)) {
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_]/.test(src[j])) j++;
      toks.push({ type: 'id', value: src.slice(i, j), line });
      i = j;
      continue;
    }
    // punctuator
    let matched = '';
    for (const p of PUNCT) {
      if (src.startsWith(p, i)) {
        matched = p;
        break;
      }
    }
    if (!matched) throw new CompileError(`unexpected character ${JSON.stringify(c)}`, line);
    toks.push({ type: 'punct', value: matched, line });
    i += matched.length;
  }
  toks.push({ type: 'eof', value: '', line });
  return toks;
}

// --- AST -------------------------------------------------------------

type Node =
  | { k: 'const'; v: bigint; line: number }
  | { k: 'id'; name: string; line: number }
  | { k: 'binop'; op: string; l: Node; r: Node; line: number }
  | { k: 'unop'; op: string; e: Node; line: number }
  | { k: 'arrayref'; base: Node; index: Node; line: number }
  | { k: 'call'; name: string; args: Node[]; line: number }
  | { k: 'cast'; e: Node; line: number };

type Stmt =
  | { k: 'decl'; name: string; init: Node | null; isPtr: boolean; line: number }
  | { k: 'assign'; op: string; lhs: Node; rhs: Node; line: number }
  | { k: 'for'; initName: string; bound: Node; body: Stmt[]; line: number }
  | { k: 'if'; cond: Node; body: Stmt[]; line: number }
  | { k: 'return'; e: Node | null; line: number }
  | { k: 'exprcall'; call: Node; line: number }
  | { k: 'incdec'; name: string; delta: number; line: number };

interface Param {
  name: string;
  isPtr: boolean;
  line: number;
}
interface FuncDef {
  name: string;
  params: Param[];
  body: Stmt[];
}

// --- parser ----------------------------------------------------------

class Parser {
  toks: Token[];
  pos = 0;
  constructor(toks: Token[]) {
    this.toks = toks;
  }
  private peek(o = 0): Token {
    return this.toks[Math.min(this.pos + o, this.toks.length - 1)];
  }
  private next(): Token {
    return this.toks[this.pos++];
  }
  private at(value: string): boolean {
    const t = this.peek();
    return t.value === value && t.type !== 'num';
  }
  private eat(value: string): Token {
    const t = this.peek();
    if (t.value !== value) throw new CompileError(`expected ${JSON.stringify(value)}, got ${JSON.stringify(t.value || 'EOF')}`, t.line);
    return this.next();
  }
  private isTypeKw(t: Token): boolean {
    return t.type === 'id' && TYPE_KEYWORDS.has(t.value);
  }

  /** Consume a type-specifier sequence; return whether it ends in `*`. */
  private parseTypeSpec(): { isPtr: boolean } {
    if (!this.isTypeKw(this.peek())) throw new CompileError(`expected a type, got ${JSON.stringify(this.peek().value)}`, this.peek().line);
    while (this.isTypeKw(this.peek())) this.next();
    let isPtr = false;
    while (this.at('*')) {
      this.next();
      isPtr = true;
    }
    return { isPtr };
  }

  parseFunction(): FuncDef {
    // [type] name ( params ) { body }
    this.parseTypeSpec();
    const nameTok = this.next();
    if (nameTok.type !== 'id') throw new CompileError('expected function name', nameTok.line);
    this.eat('(');
    const params: Param[] = [];
    if (!this.at(')')) {
      do {
        if (this.isTypeKw(this.peek()) && this.peek().value === 'void' && this.peek(1).value === ')') {
          this.next();
          break;
        }
        const { isPtr } = this.parseTypeSpec();
        const pn = this.next();
        if (pn.type !== 'id') throw new CompileError('expected parameter name', pn.line);
        params.push({ name: pn.value, isPtr, line: pn.line });
      } while (this.at(',') && this.next());
    }
    this.eat(')');
    this.eat('{');
    const body = this.parseBlock();
    this.eat('}');
    return { name: nameTok.value, params, body };
  }

  private parseBlock(): Stmt[] {
    const out: Stmt[] = [];
    while (!this.at('}') && this.peek().type !== 'eof') {
      out.push(this.parseStmt());
    }
    return out;
  }

  private parseStmt(): Stmt {
    const t = this.peek();
    if (t.value === 'for') return this.parseFor();
    if (t.value === 'if') return this.parseIf();
    if (t.value === 'return') return this.parseReturn();
    if (t.value === '{') {
      this.eat('{');
      const b = this.parseBlock();
      this.eat('}');
      // flatten compound into a synthetic if(true)? simplest: return as group
      return { k: 'if', cond: { k: 'const', v: 1n, line: t.line }, body: b, line: t.line } as Stmt;
    }
    if (this.isTypeKw(t)) return this.parseDecl();
    // assignment / call / incdec
    return this.parseSimpleStmt();
  }

  private parseDecl(): Stmt {
    const { isPtr } = this.parseTypeSpec();
    const nameTok = this.next();
    if (nameTok.type !== 'id') throw new CompileError('expected variable name', nameTok.line);
    let init: Node | null = null;
    if (this.at('=')) {
      this.next();
      init = this.parseExpr();
    }
    this.eat(';');
    return { k: 'decl', name: nameTok.value, init, isPtr, line: nameTok.line };
  }

  private parseFor(): Stmt {
    const line = this.eat('for').line;
    this.eat('(');
    // init: int i = 0
    if (!this.isTypeKw(this.peek())) throw new CompileError('for-init must declare i', line);
    this.parseTypeSpec();
    const initName = this.next().value;
    this.eat('=');
    const zero = this.parseExpr();
    if (!(zero.k === 'const' && zero.v === 0n)) throw new CompileError('for-init must be `i = 0`', line);
    this.eat(';');
    // cond: i < N
    const cond = this.parseExpr();
    if (cond.k !== 'binop' || cond.op !== '<' || cond.l.k !== 'id' || cond.l.name !== initName) {
      throw new CompileError('for-cond must be `i < N` using the init variable', line);
    }
    const bound = cond.r;
    this.eat(';');
    // iter: i++ (parse and ignore — LOOP handles the count)
    this.parseForIter(initName);
    this.eat(')');
    const body = this.parseBracedOrSingle();
    return { k: 'for', initName, bound, body, line };
  }

  private parseForIter(name: string): void {
    // accept i++, ++i, i += 1
    const t = this.peek();
    if (t.value === '++' || t.value === '--') {
      this.next();
      this.next(); // name
      return;
    }
    if (t.type === 'id') {
      this.next();
      const op = this.peek().value;
      if (op === '++' || op === '--') {
        this.next();
        return;
      }
      // i += 1 etc — consume to ')'
      while (!this.at(')') && this.peek().type !== 'eof') this.next();
      return;
    }
  }

  private parseIf(): Stmt {
    const line = this.eat('if').line;
    this.eat('(');
    const cond = this.parseExpr();
    this.eat(')');
    const body = this.parseBracedOrSingle();
    if (this.at('else')) throw new CompileError('if-else not supported', line);
    return { k: 'if', cond, body, line };
  }

  private parseReturn(): Stmt {
    const line = this.eat('return').line;
    let e: Node | null = null;
    if (!this.at(';')) e = this.parseExpr();
    this.eat(';');
    return { k: 'return', e, line };
  }

  private parseBracedOrSingle(): Stmt[] {
    if (this.at('{')) {
      this.eat('{');
      const b = this.parseBlock();
      this.eat('}');
      return b;
    }
    return [this.parseStmt()];
  }

  private parseSimpleStmt(): Stmt {
    const line = this.peek().line;
    // incdec: IDENT ++/--
    if (this.peek().type === 'id' && (this.peek(1).value === '++' || this.peek(1).value === '--')) {
      const name = this.next().value;
      const op = this.next().value;
      this.eat(';');
      return { k: 'incdec', name, delta: op === '++' ? 1 : -1, line };
    }
    const lhs = this.parseExpr();
    if (this.peek().type === 'punct' && /^(=|\+=|-=|\*=|&=|\|=|\^=|<<=|>>=)$/.test(this.peek().value)) {
      const op = this.next().value;
      const rhs = this.parseExpr();
      this.eat(';');
      return { k: 'assign', op, lhs, rhs, line };
    }
    // bare call statement
    this.eat(';');
    if (lhs.k !== 'call') throw new CompileError('expected assignment or call statement', line);
    return { k: 'exprcall', call: lhs, line };
  }

  // expression parsing with precedence climbing
  parseExpr(): Node {
    return this.parseBin(0);
  }

  private static PREC: Record<string, number> = {
    '|': 1,
    '^': 2,
    '&': 3,
    '==': 4,
    '!=': 4,
    '<': 5,
    '>=': 5,
    '<=': 5,
    '>': 5,
    '<<': 6,
    '>>': 6,
    '+': 7,
    '-': 7,
    '*': 8,
    '/': 8,
    '%': 8,
  };

  private parseBin(minPrec: number): Node {
    let left = this.parseUnary();
    for (;;) {
      const t = this.peek();
      if (t.type !== 'punct') break;
      const prec = Parser.PREC[t.value];
      if (prec === undefined || prec < minPrec) break;
      this.next();
      const right = this.parseBin(prec + 1);
      left = { k: 'binop', op: t.value, l: left, r: right, line: t.line };
    }
    return left;
  }

  private parseUnary(): Node {
    const t = this.peek();
    if (t.value === '-' || t.value === '!' || t.value === '~' || t.value === '+') {
      this.next();
      const e = this.parseUnary();
      if (t.value === '+') return e;
      return { k: 'unop', op: t.value, e, line: t.line };
    }
    // cast: ( type ) unary
    if (t.value === '(' && this.isTypeKw(this.peek(1))) {
      this.next(); // (
      this.parseTypeSpec();
      this.eat(')');
      const e = this.parseUnary();
      return { k: 'cast', e, line: t.line };
    }
    return this.parsePostfix();
  }

  private parsePostfix(): Node {
    let e = this.parsePrimary();
    for (;;) {
      const t = this.peek();
      if (t.value === '[') {
        this.next();
        const index = this.parseExpr();
        this.eat(']');
        e = { k: 'arrayref', base: e, index, line: t.line };
      } else if (t.value === '(' && e.k === 'id') {
        this.next();
        const args: Node[] = [];
        if (!this.at(')')) {
          do {
            args.push(this.parseExpr());
          } while (this.at(',') && this.next());
        }
        this.eat(')');
        e = { k: 'call', name: (e as any).name, args, line: t.line };
      } else {
        break;
      }
    }
    return e;
  }

  private parsePrimary(): Node {
    const t = this.next();
    if (t.type === 'num') return { k: 'const', v: parseNum(t.value, t.line), line: t.line };
    if (t.type === 'id') return { k: 'id', name: t.value, line: t.line };
    if (t.value === '(') {
      const e = this.parseExpr();
      this.eat(')');
      return e;
    }
    throw new CompileError(`unexpected token ${JSON.stringify(t.value || 'EOF')}`, t.line);
  }
}

function parseNum(v: string, line: number): bigint {
  let s = v.replace(/[uUlL]+$/, '').replace(/_/g, '');
  try {
    if (/^0[xX]/.test(s)) return BigInt(s);
    if (/^0[bB]/.test(s)) return BigInt(s);
    return BigInt(s);
  } catch {
    throw new CompileError(`bad numeric literal ${JSON.stringify(v)}`, line);
  }
}

// --- symbol table ----------------------------------------------------

interface Symbol {
  name: string;
  reg: number;
  isArg: boolean;
  isPtr: boolean;
  region: string | null;
}

class SymTable {
  static SCRATCH_MIN = 9;
  static SCRATCH_MAX = 15;
  symbols = new Map<string, Symbol>();
  nextArg = 1;
  scratchUsed: boolean[] = new Array(SymTable.SCRATCH_MAX + 1).fill(false);

  addArg(name: string, isPtr: boolean, region: string | null): Symbol {
    if (this.nextArg > 8) throw new CompileError(`too many arguments (>8): ${name}`);
    const s: Symbol = { name, reg: this.nextArg, isArg: true, isPtr, region };
    this.symbols.set(name, s);
    this.nextArg++;
    return s;
  }
  addLocal(name: string): Symbol {
    for (let r = SymTable.SCRATCH_MIN; r <= SymTable.SCRATCH_MAX; r++) {
      if (!this.scratchUsed[r]) {
        this.scratchUsed[r] = true;
        const s: Symbol = { name, reg: r, isArg: false, isPtr: false, region: null };
        this.symbols.set(name, s);
        return s;
      }
    }
    throw new CompileError(`out of scratch registers binding ${JSON.stringify(name)}`);
  }
  temp(): number {
    for (let r = SymTable.SCRATCH_MAX; r >= SymTable.SCRATCH_MIN; r--) {
      if (!this.scratchUsed[r]) {
        this.scratchUsed[r] = true;
        return r;
      }
    }
    throw new CompileError('out of scratch registers (temporary)');
  }
  free(reg: number): void {
    if (reg >= SymTable.SCRATCH_MIN && reg <= SymTable.SCRATCH_MAX) this.scratchUsed[reg] = false;
  }
  get(name: string): Symbol {
    const s = this.symbols.get(name);
    if (!s) throw new CompileError(`unknown symbol ${JSON.stringify(name)}`);
    return s;
  }
}

// --- compiler --------------------------------------------------------

interface RegionDef {
  name: string;
  rid: number;
  size: bigint;
}

export interface CompileResult {
  tasm: string;
  regions: RegionDef[];
}

class Compiler {
  lines: string[] = [];
  sym = new SymTable();
  regions = new Map<string, RegionDef>();
  nextRid = 0;
  labelId = 0;

  compile(src: string): CompileResult {
    const toks = lex(preprocess(src));
    const fn = new Parser(toks).parseFunction();
    this.lowerFunction(fn);
    return { tasm: this.lines.join('\n') + '\n', regions: [...this.regions.values()] };
  }

  private lowerFunction(fn: FuncDef): void {
    this.lines.push(`// Auto-generated by tiara_cc (TS) from ${fn.name}`);
    this.lines.push('// Do not edit — recompile from C source.');
    this.lines.push('');
    for (const p of fn.params) this.declareArg(p);
    for (const region of this.regions.values()) this.lines.push(`  .region ${region.name} ${region.rid}`);
    for (const s of this.sym.symbols.values()) if (s.isArg) this.lines.push(`  .arg ${s.name} r${s.reg}`);
    if (this.regions.size || [...this.sym.symbols.values()].some((s) => s.isArg)) this.lines.push('');
    for (const stmt of fn.body) this.lowerStmt(stmt);
    if (this.lines.length === 0 || !this.lines[this.lines.length - 1].toUpperCase().includes('RET')) {
      this.lines.push('  RET r0');
    }
  }

  private declareArg(p: Param): void {
    let region: string | null = null;
    let size = 1n << 30n;
    if (p.isPtr) {
      const mark = '_in_';
      if (p.name.includes(mark)) {
        const rest = p.name.slice(p.name.indexOf(mark) + mark.length);
        if (rest.includes('_')) {
          const idx = rest.lastIndexOf('_');
          const head = rest.slice(0, idx);
          const tail = rest.slice(idx + 1);
          try {
            size = BigInt(/^0[xX]/.test(tail) ? tail : tail);
            region = head;
          } catch {
            region = rest;
          }
        } else {
          region = rest;
        }
      } else {
        region = p.name;
      }
      if (region && !this.regions.has(region)) {
        this.regions.set(region, { name: region, rid: this.nextRid++, size });
      }
    }
    this.sym.addArg(p.name, p.isPtr, region);
  }

  private lowerStmt(s: Stmt): void {
    switch (s.k) {
      case 'decl':
        return this.lowerDecl(s);
      case 'assign':
        return this.lowerAssign(s);
      case 'for':
        return this.lowerFor(s);
      case 'if':
        return this.lowerIf(s);
      case 'return':
        return this.lowerReturn(s);
      case 'exprcall':
        this.lowerCall(s.call as any, false);
        return;
      case 'incdec': {
        const sym = this.sym.get(s.name);
        this.lines.push(`  ADDI r${sym.reg}, r${sym.reg}, ${s.delta}`);
        return;
      }
    }
  }

  private lowerDecl(d: { k: 'decl'; name: string; init: Node | null; line: number }): void {
    const sym = this.sym.addLocal(d.name);
    if (d.init !== null) {
      const r = this.lowerExpr(d.init);
      this.lines.push(`  ADDI r${sym.reg}, r${r}, 0`);
      this.maybeFreeTemp(r);
    }
  }

  private lowerAssign(a: { k: 'assign'; op: string; lhs: Node; rhs: Node; line: number }): void {
    if (a.op !== '=') {
      const base = a.op[0];
      const folded: Node = { k: 'binop', op: base, l: a.lhs, r: a.rhs, line: a.line };
      return this.lowerAssign({ k: 'assign', op: '=', lhs: a.lhs, rhs: folded, line: a.line });
    }
    if (a.lhs.k === 'id') {
      const sym = this.sym.get(a.lhs.name);
      const r = this.lowerExpr(a.rhs);
      this.lines.push(`  ADDI r${sym.reg}, r${r}, 0`);
      this.maybeFreeTemp(r);
      return;
    }
    if (a.lhs.k === 'arrayref') {
      const [base, off] = this.addrComponents(a.lhs);
      const r = this.lowerExpr(a.rhs);
      this.lines.push(`  STORE [r${base} + ${off}], r${r}`);
      this.maybeFreeTemp(r);
      return;
    }
    throw new CompileError(`unsupported lvalue`, a.line);
  }

  private lowerFor(f: { k: 'for'; initName: string; bound: Node; body: Stmt[]; line: number }): void {
    const indSym = this.sym.addLocal(f.initName);
    const boundReg = this.lowerExpr(f.bound);
    const endLbl = this.fresh('for_end');
    this.lines.push(`  LOOP r${boundReg}, ${endLbl}`);
    for (const x of f.body) this.lowerStmt(x);
    // Materialize the induction variable so `i` is usable inside the body
    // (e.g. as an array index). The Tiara LOOP opcode tracks the iteration
    // count internally; this explicit increment is a strict superset of the
    // reference compiler, which omits it and assumes `i` is never read.
    this.lines.push(`  ADDI r${indSym.reg}, r${indSym.reg}, 1`);
    this.lines.push(`${endLbl}:`);
    this.maybeFreeTemp(boundReg);
    this.sym.free(indSym.reg);
    this.sym.symbols.delete(f.initName);
  }

  private lowerIf(i: { k: 'if'; cond: Node; body: Stmt[]; line: number }): void {
    // const-true synthetic block (from a bare compound) — just emit body.
    if (i.cond.k === 'const' && i.cond.v !== 0n) {
      for (const x of i.body) this.lowerStmt(x);
      return;
    }
    const condReg = this.lowerCondNegated(i.cond);
    const skipLbl = this.fresh('if_skip');
    this.lines.push(`  JUMP r${condReg}, ${skipLbl}`);
    this.maybeFreeTemp(condReg);
    for (const x of i.body) this.lowerStmt(x);
    this.lines.push(`${skipLbl}:`);
  }

  private lowerReturn(r: { k: 'return'; e: Node | null; line: number }): void {
    if (r.e === null) {
      this.lines.push('  RET r0');
      return;
    }
    const rsrc = this.lowerExpr(r.e);
    if (rsrc !== 1) this.lines.push(`  ADDI r1, r${rsrc}, 0`);
    this.lines.push('  RET r1');
    this.maybeFreeTemp(rsrc);
  }

  private lowerExpr(e: Node): number {
    switch (e.k) {
      case 'const': {
        const r = this.sym.temp();
        this.lines.push(`  LI r${r}, ${e.v.toString()}`);
        return r;
      }
      case 'id':
        return this.sym.get(e.name).reg;
      case 'binop':
        return this.lowerBinop(e);
      case 'unop':
        return this.lowerUnop(e);
      case 'arrayref': {
        const [base, off] = this.addrComponents(e);
        const r = this.sym.temp();
        this.lines.push(`  LOAD r${r}, [r${base} + ${off}]`);
        return r;
      }
      case 'call':
        return this.lowerCall(e, true);
      case 'cast':
        return this.lowerExpr(e.e);
    }
  }

  private lowerBinop(b: { k: 'binop'; op: string; l: Node; r: Node; line: number }): number {
    const opMapImm: Record<string, string> = { '+': 'ADDI', '&': 'ANDI', '<<': 'SHLI', '>>': 'SHRI' };
    const opMapReg: Record<string, string> = {
      '+': 'ADD',
      '-': 'SUB',
      '*': 'MUL',
      '&': 'AND',
      '|': 'OR',
      '^': 'XOR',
      '<<': 'SHL',
      '>>': 'SHR',
      '==': 'EQ',
      '<': 'LT',
      '>=': 'GE',
    };
    const rhsConst = this.tryConst(b.r);
    if (rhsConst !== null && b.op in opMapImm) {
      const ra = this.lowerExpr(b.l);
      const rd = this.sym.temp();
      this.lines.push(`  ${opMapImm[b.op]} r${rd}, r${ra}, ${rhsConst.toString()}`);
      this.maybeFreeTemp(ra);
      return rd;
    }
    if (!(b.op in opMapReg)) throw new CompileError(`binary op ${JSON.stringify(b.op)} not supported`, b.line);
    const ra = this.lowerExpr(b.l);
    const rb = this.lowerExpr(b.r);
    const rd = this.sym.temp();
    this.lines.push(`  ${opMapReg[b.op]} r${rd}, r${ra}, r${rb}`);
    this.maybeFreeTemp(ra);
    this.maybeFreeTemp(rb);
    return rd;
  }

  private lowerUnop(u: { k: 'unop'; op: string; e: Node; line: number }): number {
    if (u.op === '-') {
      const r = this.lowerExpr(u.e);
      const rd = this.sym.temp();
      this.lines.push(`  SUB r${rd}, r0, r${r}`);
      this.maybeFreeTemp(r);
      return rd;
    }
    if (u.op === '!') {
      const r = this.lowerExpr(u.e);
      const rd = this.sym.temp();
      this.lines.push(`  EQ r${rd}, r${r}, r0`);
      this.maybeFreeTemp(r);
      return rd;
    }
    throw new CompileError(`unary op ${JSON.stringify(u.op)} not supported`, u.line);
  }

  private lowerCondNegated(e: Node): number {
    if (e.k === 'binop' && e.op === '==') {
      const ra = this.lowerExpr(e.l);
      const rb = this.lowerExpr(e.r);
      const rd = this.sym.temp();
      this.lines.push(`  EQ r${rd}, r${ra}, r${rb}`);
      const tmp = this.sym.temp();
      this.lines.push(`  LI r${tmp}, 1`);
      this.lines.push(`  XOR r${rd}, r${rd}, r${tmp}`);
      this.maybeFreeTemp(ra);
      this.maybeFreeTemp(rb);
      this.maybeFreeTemp(tmp);
      return rd;
    }
    const r = this.lowerExpr(e);
    const rd = this.sym.temp();
    this.lines.push(`  EQ r${rd}, r${r}, r0`);
    this.maybeFreeTemp(r);
    return rd;
  }

  private lowerCall(c: { k: 'call'; name: string; args: Node[]; line: number }, _wantValue: boolean): number {
    const name = c.name;
    const args = c.args;
    if (name === 'tiara_andi') {
      if (args.length !== 2) throw new CompileError('tiara_andi(x, mask)', c.line);
      const ra = this.lowerExpr(args[0]);
      const mask = this.requireConst(args[1], c.line);
      const rd = this.sym.temp();
      this.lines.push(`  ANDI r${rd}, r${ra}, 0x${mask.toString(16)}`);
      this.maybeFreeTemp(ra);
      return rd;
    }
    if (name === 'tiara_memcpy') {
      if (args.length !== 4) throw new CompileError('tiara_memcpy(dst, src, len, async_flag)', c.line);
      const rd = this.lowerExpr(args[0]);
      const rs = this.lowerExpr(args[1]);
      const ln = this.requireConst(args[2], c.line);
      const asyncf = this.requireConst(args[3], c.line);
      const tag = asyncf ? 'ASYNC' : '';
      this.lines.push(`  MEMCPY r0, r${rd}, r${rs}, LEN=${ln.toString()}${tag ? ', ' + tag : ''}`);
      this.maybeFreeTemp(rd);
      this.maybeFreeTemp(rs);
      return 0;
    }
    if (name === 'tiara_cas') {
      if (args.length !== 3) throw new CompileError('tiara_cas(addr, exp, new)', c.line);
      const ra = this.lowerExpr(args[0]);
      const re = this.lowerExpr(args[1]);
      const rn = this.lowerExpr(args[2]);
      const rd = this.sym.temp();
      this.lines.push(`  CAS r${rd}, r${ra}, r${re}, r${rn}`);
      this.maybeFreeTemp(ra);
      this.maybeFreeTemp(re);
      this.maybeFreeTemp(rn);
      return rd;
    }
    if (name === 'tiara_caa') {
      if (args.length !== 2) throw new CompileError('tiara_caa(addr, addend)', c.line);
      const ra = this.lowerExpr(args[0]);
      const rb = this.lowerExpr(args[1]);
      const rd = this.sym.temp();
      this.lines.push(`  CAA r${rd}, r${ra}, r${rb}`);
      this.maybeFreeTemp(ra);
      this.maybeFreeTemp(rb);
      return rd;
    }
    if (name === 'tiara_wait') {
      if (args.length !== 1) throw new CompileError('tiara_wait(threshold)', c.line);
      const n = this.requireConst(args[0], c.line);
      this.lines.push(`  WAIT ${n.toString()}`);
      return 0;
    }
    if (name === 'tiara_set_result') {
      if (args.length !== 2) throw new CompileError('tiara_set_result(slot, val)', c.line);
      const slot = this.requireConst(args[0], c.line);
      if (!(slot >= 1n && slot <= 4n)) throw new CompileError('result slot must be 1..4', c.line);
      const r = this.lowerExpr(args[1]);
      this.lines.push(`  ADDI r${slot.toString()}, r${r}, 0`);
      this.maybeFreeTemp(r);
      return 0;
    }
    throw new CompileError(`unknown function ${JSON.stringify(name)}`, c.line);
  }

  private addrComponents(ar: { k: 'arrayref'; base: Node; index: Node; line: number }): [number, string] {
    if (ar.base.k !== 'id') throw new CompileError('array base must be a pointer name', ar.line);
    const sym = this.sym.get(ar.base.name);
    if (!sym.isPtr) throw new CompileError(`${JSON.stringify(sym.name)} is not a pointer`, ar.line);
    const c = this.tryConst(ar.index);
    if (c !== null) return [sym.reg, (c * 8n).toString()];
    const ridx = this.lowerExpr(ar.index);
    const rscale = this.sym.temp();
    this.lines.push(`  SHLI r${rscale}, r${ridx}, 3`);
    const rsum = this.sym.temp();
    this.lines.push(`  ADD r${rsum}, r${sym.reg}, r${rscale}`);
    this.maybeFreeTemp(ridx);
    this.sym.free(rscale);
    return [rsum, '0'];
  }

  private tryConst(e: Node): bigint | null {
    if (e.k === 'const') return e.v;
    if (e.k === 'unop' && e.op === '-') {
      const inner = this.tryConst(e.e);
      return inner === null ? null : -inner;
    }
    if (e.k === 'cast') return this.tryConst(e.e);
    return null;
  }

  private requireConst(e: Node, line: number): bigint {
    const v = this.tryConst(e);
    if (v === null) throw new CompileError('constant required here', line);
    return v;
  }

  private maybeFreeTemp(r: number): void {
    for (const s of this.sym.symbols.values()) if (s.reg === r) return;
    this.sym.free(r);
  }

  private fresh(prefix: string): string {
    this.labelId++;
    return `${prefix}_${this.labelId}`;
  }
}

export function compileC(src: string): CompileResult {
  return new Compiler().compile(src);
}
