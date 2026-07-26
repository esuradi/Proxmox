export default function Home() {
  return (
    <>
      <h1>Public Cloud Portal</h1>
      <div className="card">
        <h2>Phase 1</h2>
        <p>Proxmox inventory, approved-template provisioning, Keycloak identity, RBAC, and API-first automation.</p>
      </div>
      <div className="card">
        <h2>Security boundary</h2>
        <p>The browser communicates only with the portal API. Proxmox credentials never enter the browser.</p>
      </div>
    </>
  );
}
