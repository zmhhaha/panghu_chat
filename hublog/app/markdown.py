"""Render post Markdown without accepting author-supplied HTML."""

import nh3
from markdown_it import MarkdownIt


_parser = MarkdownIt("commonmark", {
    "html": False,
    "breaks": True,
    "linkify": True,
}).enable(["table", "strikethrough", "linkify"])

_tags = {
    "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
    "strong", "em", "s", "blockquote", "ul", "ol", "li", "pre", "code",
    "a", "img", "table", "thead", "tbody", "tr", "th", "td",
}


def render_markdown(content: str) -> str:
    # Disable raw HTML in the parser and sanitize the generated output as a
    # second boundary. Never pass the original Markdown directly to innerHTML.
    return nh3.clean(
        _parser.render(content),
        tags=_tags,
        attributes={
            "a": {"href", "title"},
            "img": {"src", "alt", "title"},
            "ol": {"start"},
            "code": {"class"},
        },
        url_schemes={"http", "https", "mailto"},
        link_rel="nofollow noopener noreferrer",
    )
