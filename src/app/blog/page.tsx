import fs from "fs";
import path from "path";
import matter from "gray-matter";
import Link from "next/link";

function getPosts() {
  const dir = path.join(process.cwd(), "content/blog");
  if (!fs.existsSync(dir)) return [];
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".md"));
  return files
    .map((file) => {
      const slug = file.replace(/\.md$/, "");
      const raw = fs.readFileSync(path.join(dir, file), "utf-8");
      const { data } = matter(raw);
      return { slug, title: data.title, date: data.date, summary: data.summary };
    })
    .sort((a, b) => (a.date > b.date ? -1 : 1));
}

export default function BlogPage() {
  const posts = getPosts();

  return (
    <main className="min-h-screen bg-[#0a0a0a] text-white px-6 py-10 font-sans">
      <div className="max-w-3xl mx-auto">

        {/* Top bar — item count + title, Xbox style */}
        <div className="mb-6">
          <div className="text-[#00ff41] text-xs font-bold tracking-widest uppercase mb-0.5">
            {posts.length} {posts.length === 1 ? "Item" : "Items"}
          </div>
          <div className="text-white text-2xl font-extrabold uppercase tracking-wide">
            Development Log
          </div>
          <div className="h-[2px] bg-gradient-to-r from-[#00ff41]/80 to-transparent mt-2" />
        </div>

        {/* Post list */}
        <div className="space-y-0">
          {posts.map((post, i) => (
            <Link key={post.slug} href={`/blog/${post.slug}`} className="block group">
              <div className={`
                relative px-4 py-3 -mx-4 rounded-sm transition-all
                group-hover:bg-[#00ff41] group-hover:text-black
                ${i === 0 ? "bg-[#00ff41]/10 border-l-2 border-[#00ff41]" : "border-l-2 border-transparent"}
              `}>
                <div className="font-bold text-[15px] tracking-wide group-hover:text-black">
                  {post.title}
                </div>
                <div className={`
                  text-xs mt-0.5 transition-colors
                  ${i === 0 ? "text-[#00ff41]/60" : "text-white/30"}
                  group-hover:text-black/60
                `}>
                  {post.date}
                </div>
              </div>
            </Link>
          ))}
        </div>

        {/* Selected post detail panel — shows first post's summary */}
        {posts.length > 0 && (
          <Link href={`/blog/${posts[0].slug}`} className="block group mt-10 border-t border-[#00ff41]/20 pt-6">
            <div className="text-[#00ff41]/40 text-[10px] font-bold tracking-widest uppercase mb-2">
              Latest
            </div>
            <div className="text-white font-bold text-lg mb-2 group-hover:text-[#00ff41] transition-colors">
              {posts[0].title}
            </div>
            {posts[0].summary && (
              <p className="text-white/50 text-sm leading-relaxed max-w-lg">
                {posts[0].summary}
              </p>
            )}
            <div className="mt-4 flex items-center gap-4 text-xs text-white/20">
              <span>{posts[0].date}</span>
              <span>TRINITY PROTOCOL</span>
              <span>BASE MAINNET</span>
            </div>
          </Link>
        )}
      </div>
    </main>
  );
}
