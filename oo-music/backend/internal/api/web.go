package api

import (
	"net/http"
	"path"
	"strings"
)

// spaHandler 提供构建后的前端静态文件。
// 未命中的普通页面路径回退到 index.html，API 和健康检查路径不会被前端回退吞掉。
type spaHandler struct {
	root  http.Dir
	files http.Handler
}

func newSPAHandler(root string) http.Handler {
	files := http.FileServer(http.Dir(root))
	return &spaHandler{root: http.Dir(root), files: files}
}

func (h *spaHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.NotFound(w, r)
		return
	}

	urlPath := path.Clean("/" + r.URL.Path)
	if strings.HasPrefix(urlPath, "/api/") || urlPath == "/api" || urlPath == "/healthz" {
		http.NotFound(w, r)
		return
	}

	relative := strings.TrimPrefix(urlPath, "/")
	if relative == "" || relative == "." {
		h.serveIndex(w, r)
		return
	}

	file, err := h.root.Open(relative)
	if err == nil {
		info, statErr := file.Stat()
		_ = file.Close()
		if statErr == nil && !info.IsDir() {
			h.files.ServeHTTP(w, r)
			return
		}
	}
	h.serveIndex(w, r)
}

func (h *spaHandler) serveIndex(w http.ResponseWriter, r *http.Request) {
	file, err := h.root.Open("index.html")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil || info.IsDir() {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, "index.html", info.ModTime(), file)
}
