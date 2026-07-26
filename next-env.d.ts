'use client';

import { FormEvent, useEffect, useState } from 'react';
import { apiFetch } from '@/lib/api';
import { getKeycloak } from '@/lib/auth';

type VM = { vmid: number; name: string; node?: string; status?: string; type?: string };

export default function VMsPage() {
  const [token, setToken] = useState('');
  const [vms, setVMs] = useState<VM[]>([]);
  const [error, setError] = useState('');

  async function loadVMs(accessToken: string) {
    try { setVMs(await apiFetch('/vms', accessToken)); }
    catch (e) { setError(String(e)); }
  }

  useEffect(() => {
    const kc = getKeycloak();
    kc.init({ onLoad: 'login-required', pkceMethod: 'S256' }).then((authenticated) => {
      if (authenticated && kc.token) {
        setToken(kc.token);
        loadVMs(kc.token);
      }
    }).catch((e) => setError(String(e)));
  }, []);

  async function createVM(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    try {
      await apiFetch('/vms', token, {
        method: 'POST',
        body: JSON.stringify({
          name: form.get('name'),
          cores: Number(form.get('cores')),
          memory_mb: Number(form.get('memory_mb')),
          disk_gb: Number(form.get('disk_gb')),
        }),
      });
      alert('Provisioning request accepted. Refresh after the Proxmox task completes.');
    } catch (e) { setError(String(e)); }
  }

  return (
    <>
      <h1>Virtual Machines</h1>
      {error && <p className="error">{error}</p>}
      <div className="card">
        <h2>Request VM</h2>
        <form onSubmit={createVM}>
          <input name="name" placeholder="tenant-web01" required />
          <input name="cores" type="number" defaultValue="2" min="1" max="32" />
          <input name="memory_mb" type="number" defaultValue="4096" step="512" />
          <input name="disk_gb" type="number" defaultValue="40" min="20" />
          <button type="submit">Create from approved template</button>
        </form>
      </div>
      <div className="card">
        <table>
          <thead><tr><th>VMID</th><th>Name</th><th>Node</th><th>Status</th><th>Type</th></tr></thead>
          <tbody>{vms.map(vm => <tr key={vm.vmid}><td>{vm.vmid}</td><td>{vm.name}</td><td>{vm.node}</td><td>{vm.status}</td><td>{vm.type}</td></tr>)}</tbody>
        </table>
      </div>
    </>
  );
}
