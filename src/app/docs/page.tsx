import Link from "next/link";

export default function DocsPage() {
  const docs = [
    {
      title: "Trinity Protocol",
      href: "/docs-trinity.html",
      description: "Architecture, fee model, burn mechanics, supply distribution, risk analysis.",
    },
    {
      title: "Implementation",
      href: "/docs-implementation.html",
      description: "Technical evaluation, contract params, deployment plan, known issues.",
    },
    {
      title: "Curves",
      href: "/docs-curves.html",
      description: "Interactive charts — V1 (uniform) and V2 (differentiated) curve visualizations.",
    },
  ];

  return (
    <div className="min-h-screen flex flex-col">
      <nav className="flex items-center justify-between px-6 py-4 border-b border-[#0f3460]">
        <div className="flex items-center gap-6">
          <span className="text-xl font-bold text-white">Trinity</span>
          <div className="flex gap-4 text-sm">
            <Link href="/" className="text-[#8892a4] hover:text-white transition-colors">Trade</Link>
            <Link href="/stake" className="text-[#8892a4] hover:text-white transition-colors">Stake</Link>
            <Link href="/docs" className="text-[#f0c040] font-medium">Docs</Link>
          </div>
        </div>
      </nav>

      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-lg space-y-4">
          <h1 className="text-2xl font-bold text-white mb-6">Documentation</h1>
          {docs.map((doc) => (
            <a
              key={doc.href}
              href={doc.href}
              target="_blank"
              rel="noopener noreferrer"
              className="block bg-[#16213e] rounded-xl p-5 border border-[#0f3460] hover:border-[#4ecca3] transition-colors"
            >
              <h2 className="text-lg font-semibold text-white">{doc.title}</h2>
              <p className="text-sm text-[#8892a4] mt-1">{doc.description}</p>
            </a>
          ))}
        </div>
      </main>
    </div>
  );
}
