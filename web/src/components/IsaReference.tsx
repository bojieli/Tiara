const INSTRS: { name: string; two: boolean; sem: string; group: string }[] = [
  { name: 'LOAD', two: false, sem: 'rd = MEM64(rs1 + imm) — a loaded value can be the next address', group: 'memory' },
  { name: 'STORE', two: false, sem: 'MEM64(rs1 + imm) = rs2', group: 'memory' },
  { name: 'MEMCPY', two: true, sem: 'bulk transfer with unified (device, addr); subsumes RDMA Read/Write; async + strided', group: 'memory' },
  { name: 'CAS', two: true, sem: 'atomic compare-and-swap; returns previous value', group: 'memory' },
  { name: 'CAA', two: true, sem: 'atomic compare-and-add (fetch-and-add)', group: 'memory' },
  { name: 'JUMP', two: false, sem: 'forward-only conditional branch (if rs1 != 0: PC += imm, imm > 0)', group: 'control' },
  { name: 'LOOP', two: false, sem: 'execute the next body for rs1 iterations (bounded)', group: 'control' },
  { name: 'WAIT', two: false, sem: 'stall until in-flight async ops ≤ imm (quorum sync / drain)', group: 'control' },
  { name: 'RET', two: false, sem: 'return r1–r4 to caller; halt the task', group: 'control' },
  { name: 'COMPUTE', two: false, sem: 'integer ALU op selected by sub-opcode (below)', group: 'compute' },
];

const SUBS = [
  ['ADD', 'rd = rs1 + rs2'],
  ['SUB', 'rd = rs1 − rs2'],
  ['AND', 'rd = rs1 & rs2'],
  ['OR', 'rd = rs1 | rs2'],
  ['XOR', 'rd = rs1 ^ rs2'],
  ['SHL', 'rd = rs1 << rs2'],
  ['SHR', 'rd = rs1 >> rs2 (logical)'],
  ['MUL', 'rd = rs1 * rs2'],
  ['ADDI', 'rd = rs1 + imm'],
  ['ANDI', 'rd = rs1 & imm (region mask)'],
  ['SHLI', 'rd = rs1 << imm'],
  ['SHRI', 'rd = rs1 >> imm'],
  ['LI', 'rd = imm'],
  ['EQ', 'rd = (rs1 == rs2)'],
  ['LT', 'rd = (rs1 < rs2)'],
  ['GE', 'rd = (rs1 >= rs2)'],
];

export default function IsaReference() {
  return (
    <div className="isa">
      <div className="isa-tables">
        <table className="isa-table">
          <thead>
            <tr>
              <th>Instruction</th>
              <th>Words</th>
              <th>Semantics</th>
            </tr>
          </thead>
          <tbody>
            {INSTRS.map((i) => (
              <tr key={i.name} className={`grp-${i.group}`}>
                <td>
                  <code>{i.name}</code>
                </td>
                <td className="num">{i.two ? '2' : '1'}</td>
                <td>{i.sem}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="isa-encoding">
          <h4>64-bit encoding</h4>
          <div className="encbox">
            <div className="encfield op">opcode<br /><span>8b</span></div>
            <div className="encfield">rd<br /><span>4b</span></div>
            <div className="encfield">rs1<br /><span>4b</span></div>
            <div className="encfield">rs2<br /><span>4b</span></div>
            <div className="encfield">sub<br /><span>4b</span></div>
            <div className="encfield imm">imm40 (sign-extended)<br /><span>40b</span></div>
          </div>
          <h4>Unified address (64-bit)</h4>
          <div className="encbox">
            <div className="encfield dev">device_id<br /><span>16b</span></div>
            <div className="encfield reg">region_id<br /><span>16b</span></div>
            <div className="encfield off">offset<br /><span>32b</span></div>
          </div>
          <p className="muted small">
            <code>device_id = 0</code> is the local Tiara host (host DRAM via PCIe DMA); non-zero device IDs are
            RDMA-attached peer hosts. A <code>MEMCPY</code> with a remote source is an RDMA Read; with a remote
            destination, an RDMA Write.
          </p>

          <h4>COMPUTE sub-opcodes</h4>
          <div className="sub-grid">
            {SUBS.map(([n, s]) => (
              <div key={n} className="sub">
                <code>{n}</code>
                <span>{s}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
