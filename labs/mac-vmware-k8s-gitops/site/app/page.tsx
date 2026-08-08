"use client";

import { useEffect, useMemo, useState } from "react";

type Flow = "provision" | "configure" | "reconcile" | "recover";
type CodeKey = "terraform" | "ansible" | "kubeadm" | "gitops";

const stages = [
  { id: "overview", no: "00", label: "系統總覽" },
  { id: "install", no: "01", label: "安裝位置" },
  { id: "flow", no: "02", label: "狀態流動" },
  { id: "topology", no: "03", label: "三節點拓撲" },
  { id: "settings", no: "04", label: "關鍵設定" },
  { id: "runbook", no: "05", label: "建造步驟" },
  { id: "delivery", no: "06", label: "CI/CD · GitOps" },
  { id: "observe", no: "07", label: "監控與演練" },
];

const flows: Record<Flow, { label: string; note: string; active: string[] }> = {
  provision: {
    label: "Provision",
    note: "Terraform 從 Mac 呼叫 vSphere API，clone template、配置 NIC 與磁碟，再輸出 inventory。",
    active: ["mac", "vsphere", "ubuntu"],
  },
  configure: {
    label: "Configure",
    note: "Ansible 透過 SSH 設定三台 Ubuntu；containerd 與 kubelet 使用同一個 systemd cgroup。",
    active: ["mac", "ubuntu", "runtime", "k8s"],
  },
  reconcile: {
    label: "Reconcile",
    note: "CI 只推 image 與更新 Git tag；Argo CD 比對期望狀態，將差異同步進叢集。",
    active: ["git", "argocd", "k8s", "app"],
  },
  recover: {
    label: "Recover",
    note: "Pod 或 Node 故障時，Kubernetes 補副本；宣告被手改時，Argo CD 將 drift 擰回 Git。",
    active: ["observe", "argocd", "k8s", "app"],
  },
};

const codeSamples: Record<CodeKey, { title: string; kicker: string; code: string; callouts: string[] }> = {
  terraform: {
    title: "VM 是資料結構，不是 UI 操作紀錄",
    kicker: "L1 · INFRASTRUCTURE CONTRACT",
    code: `module "k8s_node" {
  for_each = var.nodes
  source   = "../../../terraform/modules/vm"

  name       = each.key
  cpu        = each.value.cpu
  memory_mb  = each.value.memory_mb
  os_disk_gb = each.value.disk_gb

  networks = [{
    port_group = var.network
    ipv4       = each.value.ip
    netmask    = 24
    gateway    = var.gateway
  }]
}`,
    callouts: ["for_each 保證三台 VM 同構", "static IP 也是被審查的 code", "輸出 inventory 交棒給 Ansible"],
  },
  ansible: {
    title: "讓 OS 可重跑，而不是只成功一次",
    kicker: "L2 · OPERATING SYSTEM CONTRACT",
    code: `- name: Configure containerd
  ansible.builtin.template:
    src: config.toml.j2
    dest: /etc/containerd/config.toml
  notify: Restart containerd

- name: Hold Kubernetes packages
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop: [kubelet, kubeadm, kubectl]`,
    callouts: ["template 有變才 restart", "同一 minor repo 避免 version skew", "join token 短效且 no_log"],
  },
  kubeadm: {
    title: "CRI 與 kubelet 的 cgroup 必須說同一種語言",
    kicker: "L3 · CLUSTER BOOTSTRAP CONTRACT",
    code: `# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri"
  .containerd.runtimes.runc.options]
  SystemdCgroup = true

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true`,
    callouts: ["Ubuntu/systemd 選 systemd cgroup", "swap 必須關閉", "Cilium 安裝後 Node 才 Ready"],
  },
  gitops: {
    title: "部署權在 Git，不在 CI 的 kubeconfig",
    kicker: "L4 · DELIVERY CONTRACT",
    code: `syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - ApplyOutOfSyncOnly=true
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m`,
    callouts: ["CI push immutable image SHA", "Argo CD pull-based deploy", "drift 會被自動校正"],
  },
};

const runbook = [
  { day: "DAY 0", title: "建立 Ubuntu template", owner: "vSphere", result: "cloud-init + open-vm-tools 可交棒" },
  { day: "DAY 1", title: "Terraform 建三台 VM", owner: "Mac", result: "IP / CPU / RAM / disk 都進 state" },
  { day: "DAY 2", title: "Ansible 設定 node", owner: "Mac → VM", result: "containerd + kubelet systemd cgroup" },
  { day: "DAY 3", title: "kubeadm 組成叢集", owner: "Ubuntu", result: "1 CP + 2 workers，kubeconfig 回 Mac" },
  { day: "DAY 4", title: "Bootstrap 平台網路", owner: "K8s", result: "Cilium + Gateway API + MetalLB" },
  { day: "DAY 5", title: "GitLab CI 建映像", owner: "CI", result: "BuildKit 推 immutable commit SHA" },
  { day: "DAY 6", title: "Argo CD 接管交付", owner: "Git", result: "root app 種一次，之後自癒" },
  { day: "DAY 7", title: "監控、破壞、復原", owner: "Ops", result: "用 failure drill 證明不是單體" },
];

const terminalScript = [
  "$ make tf-apply",
  "✓ vSphere: k8s-cp-01 · k8s-worker-01 · k8s-worker-02",
  "✓ contract: ansible/inventory/generated.yml",
  "$ make ansible-apply",
  "✓ containerd: SystemdCgroup=true on 3 nodes",
  "✓ kubeadm: control-plane initialized; 2 workers joined",
  "$ make platform-bootstrap && make gitops-bootstrap",
  "✓ Cilium · MetalLB · Argo CD ready",
  "↻ Argo CD: Synced / Healthy · Go API replicas 3/3",
];

const drills = [
  "刪掉一個 Go API Pod，Deployment 自動補回 3",
  "把 replicas 手改成 1，Argo CD self-heal 回 Git",
  "drain worker，PDB 仍維持至少 2 個 API Pod",
  "切換 PostgreSQL primary，應用仍走穩定的 -rw Service",
  "關閉一台 VM，觀察 Longhorn replica rebuild",
];

function initialDrillState(): boolean[] {
  const fallback = Array(drills.length).fill(false) as boolean[];
  if (typeof window === "undefined") return fallback;
  try {
    const saved = window.localStorage.getItem("onprem-lab-drills");
    const parsed = saved ? JSON.parse(saved) : null;
    return Array.isArray(parsed) && parsed.length === drills.length && parsed.every((item) => typeof item === "boolean") ? parsed : fallback;
  } catch {
    window.localStorage.removeItem("onprem-lab-drills");
    return fallback;
  }
}

export default function Home() {
  const [activeStage, setActiveStage] = useState("overview");
  const [flow, setFlow] = useState<Flow>("reconcile");
  const [codeKey, setCodeKey] = useState<CodeKey>("terraform");
  const [terminalLines, setTerminalLines] = useState<string[]>([]);
  const [running, setRunning] = useState(false);
  const [checked, setChecked] = useState<boolean[]>(initialDrillState);

  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        if (visible?.target.id) setActiveStage(visible.target.id);
      },
      { rootMargin: "-20% 0px -62%", threshold: [0.15, 0.5] },
    );
    stages.forEach(({ id }) => {
      const element = document.getElementById(id);
      if (element) observer.observe(element);
    });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    window.localStorage.setItem("onprem-lab-drills", JSON.stringify(checked));
  }, [checked]);

  const completion = useMemo(() => checked.filter(Boolean).length, [checked]);

  function scrollTo(id: string) {
    document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function runTerminal() {
    if (running) return;
    setRunning(true);
    setTerminalLines([]);
    terminalScript.forEach((line, index) => {
      window.setTimeout(() => {
        setTerminalLines((current) => [...current, line]);
        if (index === terminalScript.length - 1) setRunning(false);
      }, 420 * (index + 1));
    });
  }

  function toggleDrill(index: number) {
    setChecked((current) => current.map((value, position) => (position === index ? !value : value)));
  }

  return (
    <main>
      <header className="topbar">
        <button className="brand" onClick={() => scrollTo("overview")} aria-label="回到頁首">
          <span className="brand-mark">{"//"}</span>
          <span>LOCAL / RECONCILED</span>
        </button>
        <div className="topbar-status"><span className="status-light" /> 3-NODE LAB · GUIDE v1.0</div>
        <a className="text-link" href="#runbook">開始建造 <span aria-hidden="true">↘</span></a>
      </header>

      <aside className="rail" aria-label="教學章節">
        <div className="rail-line" />
        {stages.map((stage) => (
          <button
            key={stage.id}
            className={activeStage === stage.id ? "rail-item active" : "rail-item"}
            onClick={() => scrollTo(stage.id)}
            aria-current={activeStage === stage.id ? "step" : undefined}
          >
            <span>{stage.no}</span><b>{stage.label}</b>
          </button>
        ))}
      </aside>

      <div className="content-shell">
        <section className="hero section" id="overview">
          <div className="hero-copy">
            <p className="eyebrow">BACKEND ENGINEER&apos;S ON-PREM FIELD MANUAL</p>
            <h1>從 MacBook<br />一路 <em>reconcile</em><br />到三節點 K8s</h1>
            <p className="hero-lede">
              VMware 建運算邊界，Terraform 讓 VM 可重建，Ansible 把 Ubuntu 設成 node，
              最後由 GitLab CI 與 Argo CD 把 Go API 持續送進叢集。
            </p>
            <div className="hero-actions">
              <button className="primary-action" onClick={() => scrollTo("install")}>看安裝地圖 <span>↓</span></button>
              <button className="secondary-action" onClick={() => scrollTo("settings")}>直接看關鍵設定</button>
            </div>
            <dl className="hero-stats">
              <div><dt>03</dt><dd>Ubuntu VM</dd></div>
              <div><dt>07</dt><dd>Delivery layers</dd></div>
              <div><dt>01</dt><dd>Git source of truth</dd></div>
            </dl>
          </div>

          <div className="hero-machine" aria-label="從 Mac 到 GitOps 的架構動畫">
            <div className="machine-label">SYSTEM MAP / LIVE</div>
            <div className="machine-grid" aria-hidden="true" />
            <div className="machine-flow">
              <div className="machine-unit mac-unit"><span className="unit-no">01</span><b>MAC</b><small>CLI / Git</small></div>
              <div className="signal-track"><i /><i /><i /></div>
              <div className="machine-unit vm-unit"><span className="unit-no">02</span><b>VMWARE</b><small>vSphere API</small></div>
              <div className="node-stack">
                {["CP-01", "WK-01", "WK-02"].map((node, i) => <div key={node}><span className={`node-led led-${i}`} />{node}</div>)}
              </div>
              <div className="cluster-orbit"><span>K8S</span><i /><i /><i /></div>
              <div className="reconcile-loop"><span>GIT</span><b>↻</b><small>ARGO CD</small></div>
            </div>
            <div className="machine-readout">
              <span>DESIRED</span><b>==</b><span>ACTUAL</span><strong>HEALTHY</strong>
            </div>
          </div>
        </section>

        <section className="compatibility-strip" aria-label="VMware 相容性提醒">
          <span className="warning-index">IMPORTANT / 00</span>
          <div>
            <h2>Fusion 不是 vCenter。</h2>
            <p>官方 Terraform vSphere Provider 管的是 vCenter / ESXi API。只有 Fusion 的 Mac，手動建三台 VM 後從 Ansible 開始；要跑完整 IaC，Mac 應把 CLI 連到可用的 vSphere Lab。</p>
          </div>
          <div className="compat-tags"><span>APPLE SILICON → ARM64 GUEST</span><span>FULL PATH → VSPHERE API</span></div>
        </section>

        <section className="section install-section" id="install">
          <SectionHeading index="01" kicker="PLACEMENT BEFORE INSTALLATION" title="先決定裝在哪裡，再決定怎麼裝" intro="最常見的第一個錯誤，是把 Mac、VM 與 Cluster 的責任混成一台萬能主機。三個平面各自只放它需要的工具。" />
          <div className="placement-map">
            <article className="placement-zone mac-zone">
              <div className="zone-head"><span>CONTROL</span><b>MacBook</b><i>你的操作平面</i></div>
              <div className="tool-cloud">
                {["Terraform", "Ansible", "kubectl", "Helm", "argocd", "Git"].map((tool) => <span key={tool}>{tool}</span>)}
              </div>
              <p>保留 source、credential 與 CLI。不要在 Mac 安裝 kubelet 或 containerd。</p>
              <code>brew install terraform ansible kubernetes-cli helm argocd</code>
            </article>
            <div className="placement-arrow"><span>HTTPS 443</span><i>→</i><span>SSH 22</span></div>
            <article className="placement-zone vm-zone">
              <div className="zone-head"><span>COMPUTE</span><b>Ubuntu × 3</b><i>可被替換的 node</i></div>
              <div className="tool-cloud">
                {["cloud-init", "open-vm-tools", "containerd", "kubelet", "kubeadm"].map((tool) => <span key={tool}>{tool}</span>)}
              </div>
              <p>Ansible 管 OS 基線與 runtime。Node 上沒有 Docker Engine，也不存 GitOps 宣告。</p>
              <code>SystemdCgroup = true</code>
            </article>
            <div className="placement-arrow"><span>CRI</span><i>→</i><span>API 6443</span></div>
            <article className="placement-zone cluster-zone">
              <div className="zone-head"><span>PLATFORM</span><b>K8s Cluster</b><i>持續校正的系統</i></div>
              <div className="tool-cloud">
                {["Cilium", "MetalLB", "Argo CD", "Longhorn", "CNPG", "Prometheus"].map((tool) => <span key={tool}>{tool}</span>)}
              </div>
              <p>平台與 workload 由 Git 宣告。CI 沒有 cluster-admin，也不直接 apply。</p>
              <code>selfHeal: true</code>
            </article>
          </div>
        </section>

        <section className="section flow-section" id="flow">
          <SectionHeading index="02" kicker="FOLLOW THE STATE" title="點一條路徑，看狀態怎麼流動" intro="同一套平台有四種完全不同的流。看懂誰呼叫誰，比背指令更重要。" />
          <div className="flow-controller">
            <div className="flow-tabs" role="tablist" aria-label="狀態流路徑">
              {(Object.keys(flows) as Flow[]).map((key) => (
                <button key={key} role="tab" aria-selected={flow === key} onClick={() => setFlow(key)} className={flow === key ? "active" : ""}>
                  <span>0{(Object.keys(flows) as Flow[]).indexOf(key) + 1}</span>{flows[key].label}
                </button>
              ))}
            </div>
            <div className={`flow-stage flow-${flow}`}>
              <div className="flow-note"><span>NOW TRACING</span><p>{flows[flow].note}</p></div>
              <div className="flow-pipeline">
                {[
                  ["mac", "MAC", "CLI"], ["vsphere", "VSPHERE", "API"], ["ubuntu", "UBUNTU", "VM × 3"],
                  ["runtime", "CONTAINERD", "CRI"], ["k8s", "K8S", "SCHEDULER"], ["app", "GO API", "POD × 3"],
                ].map(([id, label, sub], index) => (
                  <div className="flow-segment" key={id}>
                    <div className={flows[flow].active.includes(id) ? "flow-node active" : "flow-node"} data-node={id}>
                      <span>0{index + 1}</span><b>{label}</b><small>{sub}</small>
                    </div>
                    {index < 5 && <div className="flow-wire"><i /></div>}
                  </div>
                ))}
              </div>
              <div className="aux-loop">
                <div className={flows[flow].active.includes("git") ? "aux-node active" : "aux-node"}><b>GITLAB</b><small>CODE / IMAGE</small></div>
                <div className={flows[flow].active.includes("argocd") ? "aux-node active" : "aux-node"}><b>ARGO CD</b><small>RECONCILE</small></div>
                <div className={flows[flow].active.includes("observe") ? "aux-node active" : "aux-node"}><b>OBSERVE</b><small>METRICS / ALERTS</small></div>
              </div>
            </div>
          </div>
        </section>

        <section className="section topology-section" id="topology">
          <SectionHeading index="03" kicker="THREE NODES, NOT THREE SILOS" title="副本要跨節點，服務才不是單體" intro="題目限制三台 VM，所以控制平面是單點；但 workload、資料、storage 與 alert path 都用副本與拓撲規則，讓你真正練到 failure domain。" />
          <div className="topology-board">
            <div className="topology-labels"><span>NODE / ROLE</span><span>WORKLOAD PLACEMENT</span><span>FAILURE DOMAIN</span></div>
            {[
              { name: "k8s-cp-01", ip: ".211", role: "CONTROL + WORKLOAD", pods: ["api-1", "pg-1", "lh-r1", "alert-1"], tone: "coral" },
              { name: "k8s-worker-01", ip: ".212", role: "WORKER", pods: ["api-2", "pg-2", "lh-r2", "prom-1"], tone: "mint" },
              { name: "k8s-worker-02", ip: ".213", role: "WORKER", pods: ["api-3", "pg-3", "lh-r3", "prom-2"], tone: "yellow" },
            ].map((node, index) => (
              <article className={`node-row ${node.tone}`} key={node.name}>
                <div className="node-identity"><span>0{index + 1}</span><div><b>{node.name}</b><small>192.168.68{node.ip} · {node.role}</small></div></div>
                <div className="pod-row">{node.pods.map((pod) => <span key={pod}>{pod}</span>)}</div>
                <div className="failure-meter"><i /><i /><i /><b>1 VM</b></div>
              </article>
            ))}
            <div className="topology-summary">
              <div><strong>3×</strong><span>Go API<br />topology spread</span></div>
              <div><strong>3×</strong><span>PostgreSQL<br />primary + replicas</span></div>
              <div><strong>3×</strong><span>Longhorn<br />volume replicas</span></div>
              <div className="caveat"><b>Production gap</b><p>要宣稱 control-plane HA，擴成 3 CP + 至少 3 workers，API endpoint 再加 kube-vip 或外部 HAProxy。</p></div>
            </div>
          </div>
        </section>

        <section className="section settings-section" id="settings">
          <SectionHeading index="04" kicker="THE FOUR CONTRACTS" title="最該 review 的，不是語法" intro="每一層只挑一個最常讓整條鏈失敗的關鍵設定。切換檔案，先看設計理由，再看 code。" />
          <div className="code-workbench">
            <div className="code-nav" role="tablist" aria-label="關鍵設定檔">
              {(Object.keys(codeSamples) as CodeKey[]).map((key, index) => (
                <button key={key} role="tab" aria-selected={codeKey === key} className={codeKey === key ? "active" : ""} onClick={() => setCodeKey(key)}>
                  <span>0{index + 1}</span><b>{key}</b><small>{codeSamples[key].kicker.split(" · ")[0]}</small>
                </button>
              ))}
            </div>
            <div className="code-main">
              <div className="code-title"><span>{codeSamples[codeKey].kicker}</span><h3>{codeSamples[codeKey].title}</h3></div>
              <pre aria-live="polite"><code>{codeSamples[codeKey].code}</code></pre>
            </div>
            <div className="code-callouts">
              <span>REVIEW CHECKS</span>
              {codeSamples[codeKey].callouts.map((callout, index) => <p key={callout}><b>0{index + 1}</b>{callout}</p>)}
            </div>
          </div>
        </section>

        <section className="section runbook-section" id="runbook">
          <SectionHeading index="05" kicker="BUILD SEQUENCE" title="八天不是課表，是八個可驗收的 checkpoint" intro="每一天都要留下 artifact 與成功條件。下一層失敗時，才知道退回哪個 contract。" />
          <div className="runbook-layout">
            <div className="runbook-list">
              {runbook.map((item, index) => (
                <article key={item.day}>
                  <div className="runbook-index"><span>{item.day}</span><b>0{index}</b></div>
                  <div><h3>{item.title}</h3><p>{item.result}</p></div>
                  <small>{item.owner}</small>
                </article>
              ))}
            </div>
            <div className="terminal-panel">
              <div className="terminal-head"><span>LAB CONTROL / zsh</span><i /><i /><i /></div>
              <div className="terminal-body" aria-live="polite">
                {terminalLines.length === 0 && <p className="terminal-idle"># 按 Run，預覽整條建造鏈的 handoff</p>}
                {terminalLines.map((line, index) => <p key={`${line}-${index}`} className={line.startsWith("✓") || line.startsWith("↻") ? "terminal-ok" : ""}>{line}</p>)}
                {running && <span className="terminal-cursor" />}
              </div>
              <button className="terminal-run" onClick={runTerminal} disabled={running}>{running ? "RUNNING…" : terminalLines.length ? "RUN AGAIN ↻" : "RUN LAB PREVIEW ▶"}</button>
              <div className="terminal-foot"><span>SIMULATION ONLY</span><span>REAL COMMANDS LIVE IN MAKEFILE</span></div>
            </div>
          </div>
        </section>

        <section className="section delivery-section" id="delivery">
          <SectionHeading index="06" kicker="PULL-BASED DELIVERY" title="CI 做 artifact，Argo CD 做 deployment" intro="CI 不需要 cluster-admin。它只測試、建多架構映像、推 commit SHA，再改 GitOps overlay；真正把狀態送進叢集的是 Argo 的 pull loop。" />
          <div className="delivery-loop">
            <div className="delivery-core"><span>DESIRED</span><b>GIT</b><i>↻</i><small>reconcile</small></div>
            {[
              ["01", "COMMIT", "Go source + YAML"], ["02", "VERIFY", "test · render · scan"],
              ["03", "BUILD", "rootless BuildKit"], ["04", "REGISTRY", "image:commit-sha"],
              ["05", "PROMOTE", "update overlay tag"], ["06", "ARGO CD", "sync · prune · heal"],
            ].map(([no, title, sub], index) => <div className={`delivery-step step-${index + 1}`} key={title}><span>{no}</span><b>{title}</b><small>{sub}</small></div>)}
          </div>
          <div className="delivery-rules">
            <article><span>RULE / 01</span><h3>不要用 latest</h3><p>Commit SHA 是不可變 artifact。rollback 是把 Git tag 改回上一個 SHA。</p></article>
            <article><span>RULE / 02</span><h3>不要讓 CI kubectl apply</h3><p>否則 Git 與 cluster 會有兩個部署主人，self-heal 反而把 CI 變更蓋掉。</p></article>
            <article><span>RULE / 03</span><h3>資料層先看 diff</h3><p>Prune 很有力量。DB/PVC 變更應加 sync window、backup 與人工核准。</p></article>
          </div>
        </section>

        <section className="section observe-section" id="observe">
          <SectionHeading index="07" kicker="PROVE IT UNDER FAILURE" title="監控不是裝完 Grafana；是故障時答得出來" intro="把 failure drill 當成 Lab 的最後一組 test。勾選會保留在這台裝置，下次回來繼續。" />
          <div className="observe-grid">
            <div className="signal-table">
              <div className="signal-head"><span>SIGNAL</span><span>QUESTION</span><span>OWNER</span></div>
              {[
                ["REQUEST", "錯誤率與 p95 是否越過 SLO？", "Go API"], ["SATURATION", "CPU throttling、記憶體、HPA？", "Prometheus"],
                ["SCHEDULING", "Pod Pending 是資源還是 affinity？", "Kubernetes"], ["DATA", "replication lag、primary、backup？", "CNPG"],
                ["STORAGE", "volume replica 是否重建完成？", "Longhorn"],
              ].map((row) => <div className="signal-row" key={row[0]}><b>{row[0]}</b><span>{row[1]}</span><small>{row[2]}</small></div>)}
            </div>
            <div className="drill-panel">
              <div className="drill-head"><div><span>FAILURE DRILL</span><b>{completion}/{drills.length}</b></div><progress value={completion} max={drills.length} /></div>
              <div className="drill-list">
                {drills.map((drill, index) => (
                  <label key={drill} className={checked[index] ? "checked" : ""}>
                    <input type="checkbox" checked={checked[index]} onChange={() => toggleDrill(index)} />
                    <span className="fake-check">{checked[index] ? "✓" : `0${index + 1}`}</span><p>{drill}</p>
                  </label>
                ))}
              </div>
              <p className="drill-note">只有 restore 成功的 backup，才算 backup。只有真的拔掉一個 failure domain，才知道它是不是 cluster。</p>
            </div>
          </div>
        </section>

        <section className="closing-panel">
          <p className="eyebrow">THE LOOP TO TAKE HOME</p>
          <h2>declare → review → reconcile<br />→ observe → fail → recover</h2>
          <p>把每次復原經驗寫回 declaration，平台才會越來越可靠，而不是只累積更多 runbook。</p>
          <div><button className="primary-action" onClick={() => scrollTo("overview")}>回到系統總覽 ↑</button><a className="secondary-action" href="https://developer.hashicorp.com/terraform/tutorials/virtual-machine/vsphere-provider" target="_blank" rel="noreferrer">官方 vSphere 教學 ↗</a></div>
        </section>

        <footer>
          <span>MAC / VMWARE / UBUNTU / TERRAFORM / ANSIBLE / K8S / GITOPS</span>
          <span>Built from the onpremis_gitops platform patterns · 2026</span>
        </footer>
      </div>
    </main>
  );
}

function SectionHeading({ index, kicker, title, intro }: { index: string; kicker: string; title: string; intro: string }) {
  return (
    <div className="section-heading">
      <div className="section-index">{index}</div>
      <div><p className="eyebrow">{kicker}</p><h2>{title}</h2></div>
      <p>{intro}</p>
    </div>
  );
}
