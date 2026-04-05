"""
Shared parser utilities for the Hinoki transpiler.
"""

import re


class ParseError(Exception):
    """Raised when a .hk file has syntax errors."""
    def __init__(self, message, filename="<unknown>", line_no=0):
        self.filename = filename
        self.line_no = line_no
        super().__init__(f"{filename}:{line_no}: {message}")


def parse_symbol(text: str) -> str:
    """Parse a Ruby symbol like :name → 'name'"""
    text = text.strip().rstrip(",")
    if text.startswith(":"):
        return text[1:]
    # Strip quotes
    if text.startswith(("'", '"')) and text.endswith(("'", '"')):
        return text[1:-1]
    return text


def parse_symbol_list(text: str) -> list:
    """Parse ':a, :b, :c' → ['a', 'b', 'c']"""
    items = re.findall(r':(\w+)', text)
    if items:
        return items
    # Fallback: comma-separated values
    return [s.strip().strip(":'\"") for s in text.split(",") if s.strip()]


def parse_hash_opts(text: str) -> dict:
    """Parse Ruby-like hash options.

    Examples:
        ', presence: true, length: { max: 500 }'
        → {'presence': True, 'length': {'max': 500}}

        ', foreign_key: :post_id'
        → {'foreign_key': 'post_id'}

        ', only: [:index, :show]'
        → {'only': ['index', 'show']}

        ', except: [:create, :destroy]'
        → {'except': ['create', 'destroy']}
    """
    text = text.strip()
    if text.startswith(","):
        text = text[1:].strip()

    result = {}
    if not text:
        return result

    # Handle nested hashes { ... }
    # First, extract all nested { } blocks and replace with placeholders
    nested = {}
    counter = [0]

    def replace_nested(m):
        key = f"__NESTED_{counter[0]}__"
        counter[0] += 1
        inner = m.group(1)
        nested[key] = parse_hash_opts(inner)
        return key

    processed = re.sub(r'\{\s*([^}]*)\s*\}', replace_nested, text)

    # Handle array values [...]
    arrays = {}

    def replace_array(m):
        key = f"__ARRAY_{counter[0]}__"
        counter[0] += 1
        inner = m.group(1)
        arrays[key] = parse_symbol_list(inner)
        return key

    processed = re.sub(r'\[\s*([^\]]*)\s*\]', replace_array, processed)

    # Now parse key: value pairs
    pairs = re.findall(r'(\w+):\s*([^,]+)', processed)
    for key, value in pairs:
        value = value.strip()

        # Check placeholders
        if value in nested:
            result[key] = nested[value]
        elif value in arrays:
            result[key] = arrays[value]
        # Boolean
        elif value.lower() == "true":
            result[key] = True
        elif value.lower() == "false":
            result[key] = False
        # Number
        elif re.match(r'^-?\d+$', value):
            result[key] = int(value)
        elif re.match(r'^-?\d+\.\d+$', value):
            result[key] = float(value)
        # Symbol
        elif value.startswith(":"):
            result[key] = value[1:]
        # String
        elif value.startswith(("'", '"')):
            result[key] = value.strip("'\"")
        else:
            result[key] = value

    return result


def extract_block(lines: list, start_idx: int,
                  open_keyword: str, close_keyword: str) -> tuple:
    """Extract a block from open_keyword to matching close_keyword.

    Returns: (block_lines, end_index)
    """
    depth = 0
    block = []
    i = start_idx

    while i < len(lines):
        stripped = lines[i].strip()
        block.append(lines[i])

        # Count nesting (but not in strings/comments)
        clean = re.sub(r'#.*$', '', stripped)  # remove comments
        clean = re.sub(r'"[^"]*"', '', clean)  # remove strings
        clean = re.sub(r"'[^']*'", '', clean)

        # Check for block openers
        if re.match(rf'^{open_keyword}\b', clean) or \
           re.search(r'\bdo\b\s*$', clean) or \
           re.search(r'\bdo\s*\|', clean):
            depth += 1
        # Also count if/unless/case/begin as block openers
        if re.match(r'^(if|unless|case|begin|for|while)\b', clean):
            depth += 1

        if clean == close_keyword or re.match(rf'^{close_keyword}\s*$', clean):
            depth -= 1
            if depth <= 0:
                return block, i

        i += 1

    raise ParseError(f"Unclosed block starting at line {start_idx + 1}: "
                     f"expected '{close_keyword}'")


def indent(text: str, level: int = 1, spaces: int = 4) -> str:
    """Indent text by N levels."""
    prefix = " " * (level * spaces)
    return "\n".join(prefix + line if line.strip() else ""
                     for line in text.split("\n"))


def sanitize_identifier(name: str) -> str:
    """Remove non-alphanumeric characters from identifier."""
    return re.sub(r'[^a-zA-Z0-9_]', '', name)


def pluralize(name: str) -> str:
    """Simple English pluralization."""
    if name.endswith("s"):
        return name + "es"
    elif name.endswith("y") and name[-2] not in "aeiou":
        return name[:-1] + "ies"
    return name + "s"


def singularize(name: str) -> str:
    """Simple English singularization."""
    if name.endswith("ies"):
        return name[:-3] + "y"
    elif name.endswith("ses"):
        return name[:-2]
    elif name.endswith("s") and not name.endswith("ss"):
        return name[:-1]
    return name


def camel_to_snake(name: str) -> str:
    """CamelCase → snake_case"""
    s = re.sub(r'([A-Z])', r'_\1', name).lower().lstrip('_')
    return s


def snake_to_camel(name: str) -> str:
    """snake_case → CamelCase"""
    return "".join(w.capitalize() for w in name.split("_"))
