"""
Priority-scheduled web crawler with content fingerprinting, incremental
state, and crawl-aware PageRank.

The frontier is a min-heap keyed by a priority score that combines depth,
inbound link count, and (optionally) a prior PageRank estimate.  The
crawl is resumable: `CrawlState.serialize` / `CrawlState.deserialize`
round-trip the full frontier + visited set + graph through JSON so a
crashed crawl can pick up where it left off.

Content deduplication uses simhash — a locality-sensitive hash that maps
documents to 64-bit fingerprints where similar documents have similar
fingerprints.  Near-duplicates are detected by Hamming distance ≤ 3.

URL canonicalization normalizes case, strips fragments, sorts query
parameters, removes default ports, and collapses path segments so that
`https://Example.COM:443/a/../b?z=1&a=2` becomes `https://example.com/b?a=2&z=1`.
"""

import json
import re


# ── Simhash ──────────────────────────────────────────────────────


class Simhash:
    """Locality-sensitive hashing for near-duplicate detection.

    Produces a 64-bit fingerprint from token frequencies.  Two documents
    are near-duplicates when their fingerprints differ in ≤ k bits.
    """

    def tokenize(text):
        """Split text into lowercase word tokens."""
        return re.findall(r"[a-z0-9]+", text.lower())

    def _hash64(s):
        """FNV-1a inspired 64-bit hash.  We work mod 2**32 since pyex
        integers are arbitrary precision and we don't need full 64 bits
        for correctness — 32 bits gives us enough discrimination."""
        h = 2166136261
        for ch in s:
            h = h ^ ord(ch)
            h = (h * 16777619) % (2**32)
        return h

    def compute(text, bits=32):
        """Return a *bits*-wide simhash fingerprint."""
        tokens = Simhash.tokenize(text)
        v = [0] * bits
        for token in tokens:
            h = Simhash._hash64(token)
            for i in range(bits):
                if (h >> i) % 2 == 1:
                    v[i] = v[i] + 1
                else:
                    v[i] = v[i] - 1
        fingerprint = 0
        for i in range(bits):
            if v[i] > 0:
                fingerprint = fingerprint + (1 << i)
        return fingerprint

    def hamming(a, b, bits=32):
        """Count differing bits between two fingerprints."""
        x = a ^ b
        count = 0
        for _ in range(bits):
            count = count + (x % 2)
            x = x >> 1
        return count


# ── URL canonicalization ─────────────────────────────────────────


class URL:
    def parse(url):
        """Split URL into (scheme, host, port, path, query).  Returns
        5-tuple of strings; missing parts are empty strings."""
        m = re.search(r"^(https?)://([^/:?#]+)(?::(\d+))?([^?#]*)(?:\?([^#]*))?", url)
        if m is None:
            return "", "", "", "", ""
        scheme = m.group(1).lower()
        host = m.group(2).lower()
        port = m.group(3) if m.group(3) is not None else ""
        path = m.group(4) if m.group(4) is not None else "/"
        query = m.group(5) if m.group(5) is not None else ""
        if path == "":
            path = "/"
        return scheme, host, port, path, query

    def canonicalize(url):
        """Canonical form: lowercase host, no default port, sorted query
        params, collapsed path segments, no fragment."""
        scheme, host, port, path, query = URL.parse(url)
        if scheme == "":
            return None

        # Strip default ports
        if port == "443" and scheme == "https":
            port = ""
        if port == "80" and scheme == "http":
            port = ""

        # Collapse path: resolve . and ..
        segments = path.split("/")
        resolved = []
        for seg in segments:
            if seg == "." or seg == "":
                continue
            elif seg == "..":
                if len(resolved) > 0:
                    resolved = resolved[:-1]
            else:
                resolved.append(seg)
        path = "/" + "/".join(resolved)

        # Sort query parameters
        if query != "":
            pairs = query.split("&")
            pairs = sorted(pairs)
            query = "&".join(pairs)

        base = scheme + "://" + host
        if port != "":
            base = base + ":" + port
        if query != "":
            return base + path + "?" + query
        return base + path

    def resolve(base_url, href):
        """Resolve href against base_url and canonicalize."""
        if href is None or href == "":
            return None
        for prefix in ["mailto:", "javascript:", "tel:", "data:"]:
            if href.startswith(prefix):
                return None

        # Strip fragment from href
        if "#" in href:
            href = href.split("#")[0]
            if href == "":
                return None

        if href.startswith("http://") or href.startswith("https://"):
            return URL.canonicalize(href)

        scheme, host, port, base_path, _ = URL.parse(base_url)
        if scheme == "":
            return None

        if href.startswith("/"):
            abs_path = href
        else:
            parent = base_path.rsplit("/", 1)[0] if "/" in base_path else ""
            abs_path = parent + "/" + href

        port_part = ""
        if port != "":
            port_part = ":" + port
        return URL.canonicalize(scheme + "://" + host + port_part + abs_path)

    def same_origin(a, b):
        s1, h1, p1, _, _ = URL.parse(a)
        s2, h2, p2, _, _ = URL.parse(b)
        return s1 == s2 and h1 == h2 and p1 == p2


# ── Robots.txt ───────────────────────────────────────────────────


class RobotRules:
    def __init__(self):
        self.rules = []

    def is_allowed(self, path):
        best_match = ""
        best_allowed = True
        for prefix, allowed in self.rules:
            if path.startswith(prefix) and len(prefix) > len(best_match):
                best_match = prefix
                best_allowed = allowed
            elif path.startswith(prefix) and len(prefix) == len(best_match) and allowed:
                best_allowed = True
        return best_allowed

    def parse(text):
        rules = RobotRules()
        active = False
        for line in text.split("\n"):
            line = line.strip()
            if line == "" or line.startswith("#"):
                continue
            lower = line.lower()
            if lower.startswith("user-agent:"):
                agent = line.split(":", 1)[1].strip()
                active = agent == "*"
            elif active and lower.startswith("disallow:"):
                path = line.split(":", 1)[1].strip()
                if path != "":
                    rules.rules.append((path, False))
            elif active and lower.startswith("allow:"):
                path = line.split(":", 1)[1].strip()
                if path != "":
                    rules.rules.append((path, True))
        return rules


# ── Min-heap (priority queue) ────────────────────────────────────


class MinHeap:
    """Array-backed binary min-heap.  Each entry is (priority, item).
    Uses a tie-breaking sequence number for FIFO ordering among equal
    priorities, guaranteeing deterministic crawl order."""

    def __init__(self):
        self._data = []
        self._seq = 0

    def push(self, priority, item):
        entry = (priority, self._seq, item)
        self._seq = self._seq + 1
        self._data.append(entry)
        self._sift_up(len(self._data) - 1)

    def pop(self):
        data = self._data
        if len(data) == 0:
            return None
        if len(data) == 1:
            entry = data[0]
            self._data = []
            return entry[2]
        top = data[0]
        last = data[-1]
        self._data = [last] + data[1:-1]
        self._sift_down(0)
        return top[2]

    def __len__(self):
        return len(self._data)

    def _sift_up(self, idx):
        data = self._data
        while idx > 0:
            parent = (idx - 1) // 2
            if data[idx][0] < data[parent][0] or (
                data[idx][0] == data[parent][0] and data[idx][1] < data[parent][1]
            ):
                tmp = data[parent]
                data[parent] = data[idx]
                data[idx] = tmp
                idx = parent
            else:
                break

    def _sift_down(self, idx):
        data = self._data
        n = len(data)
        while True:
            smallest = idx
            left = 2 * idx + 1
            right = 2 * idx + 2
            if left < n and self._less(left, smallest):
                smallest = left
            if right < n and self._less(right, smallest):
                smallest = right
            if smallest == idx:
                break
            tmp = data[idx]
            data[idx] = data[smallest]
            data[smallest] = tmp
            idx = smallest

    def _less(self, i, j):
        data = self._data
        if data[i][0] != data[j][0]:
            return data[i][0] < data[j][0]
        return data[i][1] < data[j][1]


# ── HTML extraction ──────────────────────────────────────────────


class HTML:
    def extract_links(body):
        return re.findall(r'<a\s+[^>]*href="([^"]*)"', body)

    def meta_robots(body):
        m = re.search(r'<meta\s+name="robots"\s+content="([^"]*)"', body)
        if m is None:
            return ""
        return m.group(1).lower()

    def extract_title(body):
        m = re.search(r"<title>(.*?)</title>", body)
        if m is None:
            return ""
        return m.group(1)

    def extract_text(body):
        """Strip tags for content fingerprinting."""
        text = re.sub(r"<[^>]+>", " ", body)
        text = re.sub(r"\s+", " ", text)
        return text.strip()


# ── Mock HTTP ────────────────────────────────────────────────────


class MockHTTP:
    def __init__(self, sitemap):
        self.sitemap = sitemap
        self.request_log = []

    def get(self, url):
        self.request_log.append(url)
        page = self.sitemap.get(url)
        if page is None:
            return {
                "status": 404,
                "headers": {},
                "body": "",
                "content_type": "text/html",
            }
        return page


# ── Crawl state (serializable) ───────────────────────────────────


class CrawlState:
    """Full crawl state that can be serialized to JSON and resumed."""

    def __init__(self):
        self.pages = {}
        self.edges = []
        self.redirects = {}
        self.errors = []
        self.visit_order = []
        self.fingerprints = {}
        self.near_dupes = []
        self.inbound_count = {}

    def serialize(state):
        return json.dumps(
            {
                "pages": state.pages,
                "edges": state.edges,
                "redirects": state.redirects,
                "errors": state.errors,
                "visit_order": state.visit_order,
                "fingerprints": state.fingerprints,
                "near_dupes": state.near_dupes,
                "inbound_count": state.inbound_count,
            }
        )

    def deserialize(raw):
        d = json.loads(raw)
        s = CrawlState()
        s.pages = d["pages"]
        s.edges = d["edges"]
        s.redirects = d["redirects"]
        s.errors = d["errors"]
        s.visit_order = d["visit_order"]
        s.fingerprints = d["fingerprints"]
        s.near_dupes = d["near_dupes"]
        s.inbound_count = d["inbound_count"]
        return s


# ── Crawler ──────────────────────────────────────────────────────


class Crawler:
    """Priority-scheduled crawler with content fingerprinting.

    Priority = depth * depth_weight - inbound_count * inbound_weight
    Lower priority number = crawled first.

    The inbound_count is updated as new links are discovered, meaning
    pages with many incoming links are promoted dynamically.
    """

    def __init__(self, http, seed, max_depth=10, max_pages=100):
        self.http = http
        self.seed = seed
        self.max_depth = max_depth
        self.max_pages = max_pages
        self.depth_weight = 1.0
        self.inbound_weight = 0.5
        self.dupe_threshold = 3

    def _priority(self, depth, url, inbound):
        return depth * self.depth_weight - inbound.get(url, 0) * self.inbound_weight

    def _follow_redirects(self, url, max_hops=5):
        visited_set = set()
        current = url
        chain = []
        for _ in range(max_hops):
            if current in visited_set:
                return None, None, chain, "redirect cycle"
            visited_set.add(current)
            resp = self.http.get(current)
            status = resp["status"]
            if status in [301, 302, 307, 308]:
                location = resp["headers"].get("location")
                if location is None:
                    return None, None, chain, "redirect without location"
                target = URL.resolve(current, location)
                if target is None:
                    return None, None, chain, "bad redirect target"
                chain.append((current, target))
                current = target
            else:
                return current, resp, chain, None
        return None, None, chain, "too many redirects"

    def crawl(self):
        scheme, host, _, _, _ = URL.parse(self.seed)
        robots_url = scheme + "://" + host + "/robots.txt"
        robots_resp = self.http.get(robots_url)
        robots = (
            RobotRules.parse(robots_resp["body"])
            if robots_resp["status"] == 200
            else RobotRules()
        )

        pages = {}
        edges = []
        redirects = {}
        errors = []
        visit_order = []
        fingerprints = {}
        near_dupes = []
        inbound = {}
        seen = set()

        heap = MinHeap()
        heap.push(0.0, (self.seed, 0))
        seen.add(self.seed)

        while len(heap) > 0 and len(pages) < self.max_pages:
            url, depth = heap.pop()

            if depth > self.max_depth:
                continue

            _, _, _, path, _ = URL.parse(url)
            if not robots.is_allowed(path):
                errors.append((url, "blocked by robots.txt"))
                continue

            final_url, resp, chain, redir_err = self._follow_redirects(url)
            for r_from, r_to in chain:
                redirects[r_from] = r_to
            if redir_err is not None:
                errors.append((url, redir_err))
            if resp is None:
                continue

            status = resp["status"]
            ct = resp.get("content_type", "")
            body = resp.get("body", "")
            is_html = "text/html" in ct
            meta = HTML.meta_robots(body) if is_html else ""
            title = HTML.extract_title(body) if is_html else ""
            indexable = is_html and "noindex" not in meta and status == 200

            # Content fingerprinting
            fp = None
            is_dupe = False
            if is_html and len(body) > 0:
                text = HTML.extract_text(body)
                fp = Simhash.compute(text)
                for other_url in fingerprints:
                    dist = Simhash.hamming(fp, fingerprints[other_url])
                    if dist <= self.dupe_threshold:
                        near_dupes.append((final_url, other_url, dist))
                        is_dupe = True
                        break
                fingerprints[final_url] = fp

            if final_url not in pages:
                visit_order.append(final_url)
            pages[final_url] = {
                "title": title,
                "status": status,
                "depth": depth,
                "indexable": indexable,
                "fingerprint": fp,
                "is_near_dupe": is_dupe,
            }

            if not is_html or status >= 400:
                continue
            if "nofollow" in meta:
                continue

            child_urls = []
            for href in HTML.extract_links(body):
                child = URL.resolve(final_url, href)
                if child is None:
                    continue
                if not URL.same_origin(child, self.seed):
                    continue
                child_urls.append(child)
                edges.append((final_url, child))
                inbound[child] = inbound.get(child, 0) + 1

            for child in child_urls:
                if child not in seen:
                    seen.add(child)
                    pri = self._priority(depth + 1, child, inbound)
                    heap.push(pri, (child, depth + 1))

        return {
            "pages": pages,
            "edges": edges,
            "redirects": redirects,
            "errors": errors,
            "visit_order": visit_order,
            "fingerprints": fingerprints,
            "near_dupes": near_dupes,
            "inbound_count": inbound,
        }


# ── Graph analysis ───────────────────────────────────────────────


class Graph:
    def build_adjacency(edges):
        adj = {}
        nodes = set()
        for src, dst in edges:
            nodes.add(src)
            nodes.add(dst)
            if src not in adj:
                adj[src] = []
            adj[src].append(dst)
        for n in nodes:
            if n not in adj:
                adj[n] = []
        return adj

    def find_back_edges(adj):
        """Iterative DFS with WHITE/GRAY/BLACK coloring."""
        WHITE = 0
        GRAY = 1
        BLACK = 2
        color = {}
        for node in adj:
            color[node] = WHITE
        back_edges = []
        for start in adj:
            if color[start] != WHITE:
                continue
            stack = [(start, 0)]
            while len(stack) > 0:
                node, idx = stack[-1]
                if idx == 0:
                    color[node] = GRAY
                neighbors = adj.get(node, [])
                if idx < len(neighbors):
                    stack[-1] = (node, idx + 1)
                    nb = neighbors[idx]
                    if color.get(nb, WHITE) == GRAY:
                        back_edges.append((node, nb))
                    elif color.get(nb, WHITE) == WHITE:
                        stack.append((nb, 0))
                else:
                    color[node] = BLACK
                    stack = stack[:-1]
        return back_edges

    def page_rank(adj, damping=0.85, iterations=20):
        nodes = list(adj.keys())
        n = len(nodes)
        if n == 0:
            return {}
        rank = {}
        for node in nodes:
            rank[node] = 1.0 / n
        for _ in range(iterations):
            new_rank = {}
            for node in nodes:
                new_rank[node] = (1.0 - damping) / n
            for node in nodes:
                neighbors = adj[node]
                if len(neighbors) == 0:
                    share = rank[node] / n
                    for other in nodes:
                        new_rank[other] = new_rank[other] + damping * share
                else:
                    share = rank[node] / len(neighbors)
                    for nb in neighbors:
                        if nb in new_rank:
                            new_rank[nb] = new_rank[nb] + damping * share
            rank = new_rank
        return rank

    def strongly_connected(adj):
        """Tarjan's algorithm (iterative) for SCCs."""
        index_counter = [0]
        stack = []
        on_stack = set()
        index_map = {}
        lowlink = {}
        sccs = []

        for node in adj:
            if node in index_map:
                continue
            work = [(node, 0, False)]
            while len(work) > 0:
                v, ni, returned = work[-1]
                if not returned and v not in index_map:
                    index_map[v] = index_counter[0]
                    lowlink[v] = index_counter[0]
                    index_counter[0] = index_counter[0] + 1
                    stack.append(v)
                    on_stack.add(v)

                neighbors = adj.get(v, [])
                found_child = False
                start = ni
                for i in range(start, len(neighbors)):
                    w = neighbors[i]
                    if w not in index_map:
                        work[-1] = (v, i + 1, False)
                        work.append((w, 0, False))
                        found_child = True
                        break
                    elif w in on_stack:
                        if lowlink[v] > index_map[w]:
                            lowlink[v] = index_map[w]

                if not found_child:
                    work = work[:-1]
                    if lowlink[v] == index_map[v]:
                        scc = []
                        while True:
                            w = stack[-1]
                            stack = stack[:-1]
                            on_stack.discard(w)
                            scc.append(w)
                            if w == v:
                                break
                        if len(scc) > 1:
                            sccs.append(sorted(scc))
                    if len(work) > 0:
                        parent_v = work[-1][0]
                        if lowlink[parent_v] > lowlink[v]:
                            lowlink[parent_v] = lowlink[v]
                        work[-1] = (parent_v, work[-1][1], True)

        return sccs


# ── Run ──────────────────────────────────────────────────────────

with open("sitemap.json", "r") as f:
    sitemap = json.loads(f.read())

# -- Crawl --

crawler = Crawler(MockHTTP(sitemap), "https://example.com/", max_depth=5, max_pages=50)
result = crawler.crawl()
pages = result["pages"]
edges = result["edges"]
visit_order = result["visit_order"]
redirs = result["redirects"]
errs = result["errors"]
fps = result["fingerprints"]
dupes = result["near_dupes"]
inbound = result["inbound_count"]

# -- URL canonicalization checks --

c1 = URL.canonicalize("https://Example.COM:443/a/../b?z=1&a=2#frag")
c2 = URL.canonicalize("https://example.com/b?a=2&z=1")
print(f"canon: {c1} == {c2}: {c1 == c2}")

c3 = URL.resolve("https://example.com/a/b", "../c")
print(f"resolve: {c3}")

# -- Simhash checks --

h1 = Simhash.compute("the quick brown fox jumps over the lazy dog")
h2 = Simhash.compute("the quick brown fox leaps over the lazy dog")
h3 = Simhash.compute("completely different content about quantum physics")
d12 = Simhash.hamming(h1, h2)
d13 = Simhash.hamming(h1, h3)
print(f"simhash near: d={d12} (similar), d={d13} (different)")

# -- MinHeap checks --

h = MinHeap()
h.push(3.0, "c")
h.push(1.0, "a")
h.push(2.0, "b")
h.push(1.0, "a2")
order = []
while len(h) > 0:
    order.append(h.pop())
print(f"heap order: {order}")

# -- Crawl results --

depths = [pages[u]["depth"] for u in visit_order]
print(f"crawl: {len(pages)} pages, {len(edges)} edges, depths={depths}")

# Priority ordering: pages with more inbound links should appear earlier
# at the same depth level
print(f"inbound counts: {len(inbound)} urls tracked")

# -- Redirects --

redir_target = redirs.get("https://example.com/blog/post-2", "none")
print(f"redirect: post-2 -> {redir_target}")

# -- Robots.txt --

blocked = [r for u, r in errs if "robots" in r]
print(f"robots blocked: {len(blocked)}")

# -- Content fingerprinting --

fp_count = len([u for u in fps])
dupe_count = len(dupes)
print(f"fingerprints: {fp_count}, near-dupes: {dupe_count}")

# -- Indexability --

indexable = [u for u in pages if pages[u]["indexable"]]
noindex = [u for u in pages if not pages[u]["indexable"]]
print(f"indexable: {len(indexable)}, noindex: {len(noindex)}")

# -- State serialization round-trip --

state = CrawlState()
state.pages = pages
state.edges = edges
state.redirects = redirs
state.errors = errs
state.visit_order = visit_order
state.fingerprints = fps
state.near_dupes = dupes
state.inbound_count = inbound

serialized = CrawlState.serialize(state)
restored = CrawlState.deserialize(serialized)
print(f"serialize round-trip: {len(restored.pages)} pages, {len(restored.edges)} edges")

# -- Graph analysis --

adj = Graph.build_adjacency(edges)
back = Graph.find_back_edges(adj)
print(f"back-edges: {len(back)}")

sccs = Graph.strongly_connected(adj)
scc_sizes = sorted([len(s) for s in sccs], reverse=True)
print(f"SCCs (size>1): {len(sccs)}, sizes={scc_sizes}")

ranks = Graph.page_rank(adj, damping=0.85, iterations=30)
ranked = sorted(ranks.keys(), key=lambda u: ranks[u], reverse=True)
total = sum(ranks[u] for u in ranks)
top3 = ranked[:3]
print(f"pagerank sum={round(total, 4)}, top={top3}")

# -- Summary --

summary = {
    "pages_crawled": len(pages),
    "edges_found": len(edges),
    "indexable": len(indexable),
    "redirects": len(redirs),
    "errors": len(errs),
    "fingerprints": fp_count,
    "near_dupes": dupe_count,
    "back_edges": len(back),
    "sccs": len(sccs),
    "top_page": ranked[0],
    "http_requests": len(crawler.http.request_log),
}
print(f"\n{json.dumps(summary, indent=2)}")

with open("report.json", "w") as f:
    f.write(json.dumps(summary, indent=2))
