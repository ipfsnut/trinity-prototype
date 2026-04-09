import fs from "fs";
import path from "path";
import matter from "gray-matter";
import Markdown from "react-markdown";
import Link from "next/link";
import type { Components } from "react-markdown";
import { ThemeToggle } from "./ThemeToggle";

const BLOG_DIR = path.join(process.cwd(), "content/blog");

export function generateStaticParams() {
  if (!fs.existsSync(BLOG_DIR)) return [];
  return fs
    .readdirSync(BLOG_DIR)
    .filter((f) => f.endsWith(".md"))
    .map((f) => ({ slug: f.replace(/\.md$/, "") }));
}

function getAllPosts() {
  if (!fs.existsSync(BLOG_DIR)) return [];
  return fs
    .readdirSync(BLOG_DIR)
    .filter((f) => f.endsWith(".md"))
    .map((file) => {
      const slug = file.replace(/\.md$/, "");
      const raw = fs.readFileSync(path.join(BLOG_DIR, file), "utf-8");
      const { data } = matter(raw);
      return { slug, title: data.title, date: data.date };
    })
    .sort((a, b) => (a.date > b.date ? -1 : 1));
}

function getPost(slug: string) {
  const file = path.join(BLOG_DIR, `${slug}.md`);
  if (!fs.existsSync(file)) return null;
  const raw = fs.readFileSync(file, "utf-8");
  const { data, content } = matter(raw);
  return { title: data.title, date: data.date, content };
}

const mdComponents: Components = {
  h2: ({ children }) => (
    <h2 className="text-xl font-bold mt-10 mb-3 border-b border-current/15 pb-2">{children}</h2>
  ),
  h3: ({ children }) => (
    <h3 className="text-base font-semibold mt-6 mb-2 italic">{children}</h3>
  ),
  p: ({ children }) => (
    <p className="leading-7 mb-4 text-[15px]">{children}</p>
  ),
  ul: ({ children }) => (
    <ul className="list-disc pl-6 space-y-2 mb-4 text-[15px]">{children}</ul>
  ),
  ol: ({ children }) => (
    <ol className="list-decimal pl-6 space-y-2 mb-4 text-[15px]">{children}</ol>
  ),
  li: ({ children }) => (
    <li className="leading-7">{children}</li>
  ),
  strong: ({ children }) => (
    <strong className="font-bold">{children}</strong>
  ),
  a: ({ href, children }) => (
    <a href={href} className="underline decoration-current/30 hover:decoration-current transition-colors" target="_blank" rel="noopener noreferrer">{children}</a>
  ),
  code: ({ children }) => (
    <code className="text-[13px] font-mono px-1 py-0.5 rounded bg-current/5">{children}</code>
  ),
  pre: ({ children }) => (
    <pre className="bg-[#0a0a0a] text-[#00ff41] border border-[#00ff41]/20 rounded-sm p-4 overflow-x-auto mb-4 text-[13px] font-mono">{children}</pre>
  ),
  table: ({ children }) => (
    <div className="overflow-x-auto mb-4">
      <table className="w-full text-sm border-collapse font-mono">{children}</table>
    </div>
  ),
  thead: ({ children }) => (
    <thead className="border-b-2 border-current/20">{children}</thead>
  ),
  th: ({ children }) => (
    <th className="text-left py-2 pr-4 font-bold text-[13px]">{children}</th>
  ),
  td: ({ children }) => (
    <td className="py-1.5 pr-4 text-[13px] opacity-80 border-b border-current/5">{children}</td>
  ),
  hr: () => <hr className="border-current/15 my-8" />,
  blockquote: ({ children }) => (
    <blockquote className="border-l-2 border-current/30 pl-4 italic opacity-70 my-4">{children}</blockquote>
  ),
};

export default async function BlogPostPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const post = getPost(slug);
  const allPosts = getAllPosts();

  if (!post) {
    return (
      <main className="min-h-screen bg-black text-[#00ff41] px-4 py-12 max-w-3xl mx-auto">
        <p>Post not found.</p>
        <Link href="/blog" className="underline">Back to blog</Link>
      </main>
    );
  }

  return (
    <ThemeToggle>
      <div className="flex gap-0 min-h-screen">
        {/* Sidebar nav */}
        <aside className="hidden lg:block w-56 shrink-0 pr-6 border-r border-current/10 mr-8">
          <Link href="/blog" className="block text-xs font-bold tracking-widest uppercase opacity-40 hover:opacity-100 transition-opacity mb-4">
            &larr; All Posts
          </Link>
          <nav className="space-y-1">
            {allPosts.map((p) => (
              <Link
                key={p.slug}
                href={`/blog/${p.slug}`}
                className={`block text-[13px] py-1.5 px-2 -mx-2 rounded-sm transition-all leading-tight ${
                  p.slug === slug
                    ? "bg-current/10 font-bold"
                    : "opacity-40 hover:opacity-80"
                }`}
              >
                {p.title}
              </Link>
            ))}
          </nav>
        </aside>

        {/* Article */}
        <article className="flex-1 min-w-0 max-w-2xl">
          {/* Mobile back link */}
          <Link href="/blog" className="lg:hidden text-sm hover:underline mb-6 block opacity-40">
            &larr; Back
          </Link>
          <time className="text-xs opacity-30 tracking-wider uppercase">{post.date}</time>
          <h1 className="text-2xl font-bold mt-2 mb-4 leading-tight">{post.title}</h1>
          <hr className="border-current/15 mb-8" />
          <Markdown components={mdComponents}>{post.content}</Markdown>
        </article>
      </div>
    </ThemeToggle>
  );
}
