"""
Model Transpiler: model DSL → PL/SQL package

Example input:
    model Post
      table :posts
      permit :title, :body, :published
      validates :title, presence: true, length: { max: 500 }
      has_many :comments, foreign_key: :post_id
      scope :published, -> { where "published = 1" }

      def set_slug
        self.slug = lower(replace(self.title, ' ', '-'))
      end
    end

Generates:
    CREATE OR REPLACE PACKAGE post_model AS ... END;
    CREATE OR REPLACE PACKAGE BODY post_model AS ... END;
"""

import re
from .parser_utils import (
    parse_symbol, parse_symbol_list, parse_hash_opts,
    indent, sanitize_identifier, pluralize, singularize,
    extract_block, ParseError
)


class ModelTranspiler:
    def __init__(self, source: str, filename: str = "<unknown>"):
        self.source = source
        self.filename = filename
        self.lines = source.split("\n")
        self.model_name = ""
        self.table_name = ""
        self.package_name = ""
        self.permitted = []
        self.validations = []
        self.associations = []
        self.scopes = []
        self.callbacks = {"before_save": [], "after_save": [], "before_delete": []}
        self.custom_methods = []
        self.raw_blocks = []

    def transpile(self) -> str:
        self._parse()
        spec = self._generate_spec()
        body = self._generate_body()
        return f"{spec}\n/\n\n{body}\n/\n"

    # ================================================================
    # Parsing
    # ================================================================

    def _parse(self):
        i = 0
        while i < len(self.lines):
            line = self.lines[i].strip()

            # Skip empty / comments
            if not line or line.startswith("#"):
                i += 1
                continue

            # model Name
            m = re.match(r'^model\s+(\w+)', line)
            if m:
                self.model_name = m.group(1)
                self.package_name = self._to_snake(self.model_name) + "_model"
                i += 1
                continue

            # table :name
            m = re.match(r'^table\s+:(\w+)', line)
            if m:
                self.table_name = m.group(1)
                i += 1
                continue

            # permit :col1, :col2, ...
            if line.startswith("permit "):
                self.permitted = parse_symbol_list(line[7:])
                i += 1
                continue

            # validates :field, rule: value, ...
            if line.startswith("validates "):
                self._parse_validation(line)
                i += 1
                continue

            # has_many / belongs_to / has_one
            m = re.match(r'^(has_many|belongs_to|has_one)\s+:(\w+)(.*)', line)
            if m:
                self.associations.append({
                    "type": m.group(1),
                    "name": m.group(2),
                    "opts": parse_hash_opts(m.group(3)) if m.group(3).strip() else {}
                })
                i += 1
                continue

            # scope :name, -> { ... }
            m = re.match(r'^scope\s+:(\w+)\s*,\s*->\s*\{\s*(.*)\s*\}', line)
            if m:
                self._parse_scope(m.group(1), m.group(2))
                i += 1
                continue

            # before_save / after_save / before_delete
            m = re.match(r'^(before_save|after_save|before_delete)\s+:(\w+)', line)
            if m:
                self.callbacks[m.group(1)].append(m.group(2))
                i += 1
                continue

            # def method_name ... end
            if line.startswith("def "):
                method_lines, end_i = extract_block(self.lines, i, "def", "end")
                self._parse_method(method_lines)
                i = end_i + 1
                continue

            # end (model block)
            if line == "end":
                i += 1
                continue

            i += 1

        # Defaults
        if not self.table_name:
            self.table_name = pluralize(self._to_snake(self.model_name))
        if not self.package_name:
            self.package_name = self._to_snake(self.model_name) + "_model"

    def _parse_validation(self, line: str):
        """Parse: validates :field, presence: true, length: { max: 500 }"""
        rest = line[10:].strip()  # after "validates "
        parts = rest.split(",", 1)
        field = parse_symbol(parts[0].strip())
        opts = parse_hash_opts(parts[1]) if len(parts) > 1 else {}
        self.validations.append({"field": field, **opts})

    def _parse_scope(self, name: str, body: str):
        """Parse scope body: where "...", order "...", limit N"""
        scope = {"name": name, "where": None, "order": None, "limit": None}
        # Parse scope chain
        for part in re.split(r'\.\s*', body):
            part = part.strip()
            m = re.match(r'where\s+"([^"]*)"', part)
            if m:
                scope["where"] = m.group(1)
                continue
            m = re.match(r'order\s+"([^"]*)"', part)
            if m:
                scope["order"] = m.group(1)
                continue
            m = re.match(r'limit\s+(\d+)', part)
            if m:
                scope["limit"] = int(m.group(1))
        self.scopes.append(scope)

    def _parse_method(self, lines: list):
        """Parse a custom method definition."""
        header = lines[0].strip()
        m = re.match(r'^def\s+(\w+)(\(([^)]*)\))?', header)
        if not m:
            return

        method_name = m.group(1)
        params_str = m.group(3) or ""
        params = [p.strip() for p in params_str.split(",") if p.strip()]

        body_lines = lines[1:-1]  # exclude def and end

        # Check for raw_plsql block
        body_text = "\n".join(l.strip() for l in body_lines)
        raw_match = re.search(r'raw_plsql\s+<<~?SQL\s*\n(.*?)\n\s*SQL', body_text, re.DOTALL)

        if raw_match:
            self.custom_methods.append({
                "name": method_name,
                "params": params,
                "raw_plsql": raw_match.group(1),
                "body_lines": []
            })
        else:
            self.custom_methods.append({
                "name": method_name,
                "params": params,
                "raw_plsql": None,
                "body_lines": body_lines
            })

    # ================================================================
    # Code Generation - Spec
    # ================================================================

    def _generate_spec(self) -> str:
        lines = []
        lines.append(f"-- Generated by Hinoki Transpiler from {self.filename}")
        lines.append(f"-- Model: {self.model_name} | Table: {self.table_name}")
        lines.append(f"CREATE OR REPLACE PACKAGE {self.package_name} AS")
        lines.append("")
        lines.append(f"    c_table     CONSTANT VARCHAR2(200) := '{self.table_name}';")

        if self.permitted:
            cols = ", ".join(self.permitted)
            lines.append(f"    c_permitted CONSTANT VARCHAR2(1000) := '{cols}';")

        lines.append("")
        lines.append("    -- Standard CRUD")
        lines.append("    FUNCTION all_records(p_page IN NUMBER DEFAULT 1,")
        lines.append("                         p_per_page IN NUMBER DEFAULT 25) RETURN SYS_REFCURSOR;")
        lines.append("    FUNCTION find(p_id IN NUMBER) RETURN SYS_REFCURSOR;")
        lines.append("    FUNCTION create_record(p_params IN hinoki_model.t_record) RETURN NUMBER;")
        lines.append("    PROCEDURE update_record(p_id IN NUMBER, p_params IN hinoki_model.t_record);")
        lines.append("    PROCEDURE delete_record(p_id IN NUMBER);")
        lines.append("    FUNCTION validate(p_params IN hinoki_model.t_record) RETURN BOOLEAN;")

        # Scopes
        for scope in self.scopes:
            lines.append(f"    FUNCTION {scope['name']}(p_page IN NUMBER DEFAULT 1,"
                         f" p_per_page IN NUMBER DEFAULT 25) RETURN SYS_REFCURSOR;")

        # Associations
        for assoc in self.associations:
            if assoc["type"] == "has_many":
                lines.append(f"    FUNCTION {assoc['name']}(p_id IN NUMBER) RETURN SYS_REFCURSOR;")
            elif assoc["type"] in ("belongs_to", "has_one"):
                lines.append(f"    FUNCTION {assoc['name']}(p_{assoc['name']}_id IN NUMBER)"
                             " RETURN SYS_REFCURSOR;")

        # JSON helpers
        lines.append("    FUNCTION all_as_json RETURN CLOB;")
        lines.append("    FUNCTION find_as_json(p_id IN NUMBER) RETURN CLOB;")

        # Custom methods
        for method in self.custom_methods:
            params = self._method_params_spec(method)
            if method.get("raw_plsql") and "RETURN" in method["raw_plsql"].upper():
                lines.append(f"    FUNCTION {method['name']}({params}) RETURN SYS_REFCURSOR;")
            else:
                lines.append(f"    PROCEDURE {method['name']}({params});")

        lines.append("")
        lines.append(f"END {self.package_name};")
        return "\n".join(lines)

    # ================================================================
    # Code Generation - Body
    # ================================================================

    def _generate_body(self) -> str:
        lines = []
        lines.append(f"CREATE OR REPLACE PACKAGE BODY {self.package_name} AS")
        lines.append("")

        # all_records
        lines.append("    FUNCTION all_records(p_page IN NUMBER DEFAULT 1,")
        lines.append("                         p_per_page IN NUMBER DEFAULT 25) RETURN SYS_REFCURSOR IS")
        lines.append("    BEGIN")
        lines.append(f"        RETURN hinoki_model.paginate(c_table, p_page, p_per_page);")
        lines.append("    END all_records;")
        lines.append("")

        # find
        lines.append("    FUNCTION find(p_id IN NUMBER) RETURN SYS_REFCURSOR IS")
        lines.append("    BEGIN")
        lines.append("        RETURN hinoki_model.find_by_id(c_table, p_id);")
        lines.append("    END find;")
        lines.append("")

        # create_record
        lines.append("    FUNCTION create_record(p_params IN hinoki_model.t_record) RETURN NUMBER IS")
        lines.append("    BEGIN")
        lines.append("        IF NOT validate(p_params) THEN RETURN NULL; END IF;")
        self._emit_callbacks(lines, "before_save")
        lines.append("        RETURN hinoki_model.create_from_record(c_table, p_params, c_permitted);")
        lines.append("    END create_record;")
        lines.append("")

        # update_record
        lines.append("    PROCEDURE update_record(p_id IN NUMBER, p_params IN hinoki_model.t_record) IS")
        lines.append("    BEGIN")
        lines.append("        IF validate(p_params) THEN")
        self._emit_callbacks(lines, "before_save", extra_indent="    ")
        lines.append("            hinoki_model.update_from_record(c_table, p_id, p_params, c_permitted);")
        self._emit_callbacks(lines, "after_save", extra_indent="    ")
        lines.append("        END IF;")
        lines.append("    END update_record;")
        lines.append("")

        # delete_record
        lines.append("    PROCEDURE delete_record(p_id IN NUMBER) IS")
        lines.append("    BEGIN")
        self._emit_callbacks(lines, "before_delete")
        lines.append("        hinoki_model.delete_record(c_table, p_id);")
        lines.append("    END delete_record;")
        lines.append("")

        # validate
        lines.extend(self._generate_validate())
        lines.append("")

        # scopes
        for scope in self.scopes:
            lines.extend(self._generate_scope(scope))
            lines.append("")

        # associations
        for assoc in self.associations:
            lines.extend(self._generate_association(assoc))
            lines.append("")

        # JSON helpers
        cols = "id," + ",".join(self.permitted) if self.permitted else "id"
        lines.append("    FUNCTION all_as_json RETURN CLOB IS")
        lines.append("        v_cursor SYS_REFCURSOR := hinoki_model.find_all(c_table);")
        lines.append("    BEGIN")
        lines.append(f"        RETURN hinoki_model.cursor_to_json(v_cursor, '{cols}');")
        lines.append("    END all_as_json;")
        lines.append("")
        lines.append("    FUNCTION find_as_json(p_id IN NUMBER) RETURN CLOB IS")
        lines.append("        v_cursor SYS_REFCURSOR := find(p_id);")
        lines.append("    BEGIN")
        lines.append(f"        RETURN hinoki_model.row_to_json(v_cursor, '{cols}');")
        lines.append("    END find_as_json;")
        lines.append("")

        # Custom methods
        for method in self.custom_methods:
            lines.extend(self._generate_custom_method(method))
            lines.append("")

        lines.append(f"END {self.package_name};")
        return "\n".join(lines)

    def _generate_validate(self) -> list:
        lines = []
        lines.append("    FUNCTION validate(p_params IN hinoki_model.t_record) RETURN BOOLEAN IS")
        lines.append("    BEGIN")
        lines.append("        hinoki_model.clear_validations;")

        for v in self.validations:
            field = v["field"]
            if v.get("presence"):
                msg = v.get("message", f"'{field}は必須です'")
                lines.append(f"        hinoki_model.validates_presence('{field}', {msg});")

            if v.get("length"):
                length_opts = v["length"]
                min_val = length_opts.get("min", "NULL")
                max_val = length_opts.get("max", "NULL")
                msg = v.get("message", f"'{field}の長さが不正です'")
                lines.append(f"        hinoki_model.validates_length('{field}', {min_val}, {max_val}, {msg});")

            if v.get("numericality"):
                msg = v.get("message", f"'{field}は数値でなければなりません'")
                lines.append(f"        hinoki_model.validates_numericality('{field}', {msg});")

            if v.get("uniqueness"):
                msg = v.get("message", f"'{field}は既に使用されています'")
                lines.append(f"        hinoki_model.validates_uniqueness(c_table, '{field}', NULL, {msg});")

        lines.append("        RETURN hinoki_model.validate(p_params);")
        lines.append("    END validate;")
        return lines

    def _generate_scope(self, scope: dict) -> list:
        lines = []
        name = scope["name"]
        where = scope.get("where")
        order = scope.get("order", "id DESC")
        limit = scope.get("limit", 25)

        lines.append(f"    FUNCTION {name}(p_page IN NUMBER DEFAULT 1,"
                     f" p_per_page IN NUMBER DEFAULT {limit}) RETURN SYS_REFCURSOR IS")
        lines.append("    BEGIN")

        where_str = f"'{where}'" if where else "NULL"
        order_str = f"'{order}'" if order else "'id DESC'"
        lines.append(f"        RETURN hinoki_model.find_all(c_table, '*', {where_str},"
                     f" {order_str}, p_per_page,"
                     f" (GREATEST(p_page, 1) - 1) * p_per_page);")
        lines.append(f"    END {name};")
        return lines

    def _generate_association(self, assoc: dict) -> list:
        lines = []
        name = assoc["name"]
        assoc_type = assoc["type"]
        opts = assoc.get("opts", {})

        if assoc_type == "has_many":
            fk = opts.get("foreign_key", self._to_snake(self.model_name) + "_id")
            ref_table = opts.get("table", name)
            lines.append(f"    FUNCTION {name}(p_id IN NUMBER) RETURN SYS_REFCURSOR IS")
            lines.append("        v_cursor SYS_REFCURSOR;")
            lines.append("    BEGIN")
            lines.append(f"        OPEN v_cursor FOR")
            lines.append(f"            SELECT * FROM {ref_table} WHERE {fk} = p_id ORDER BY id;")
            lines.append("        RETURN v_cursor;")
            lines.append(f"    END {name};")

        elif assoc_type in ("belongs_to", "has_one"):
            ref_table = opts.get("table", pluralize(name))
            lines.append(f"    FUNCTION {name}(p_{name}_id IN NUMBER) RETURN SYS_REFCURSOR IS")
            lines.append("    BEGIN")
            lines.append(f"        RETURN hinoki_model.find_by_id('{ref_table}', p_{name}_id);")
            lines.append(f"    END {name};")

        return lines

    def _generate_custom_method(self, method: dict) -> list:
        lines = []
        name = method["name"]
        params = self._method_params_spec(method)

        if method.get("raw_plsql"):
            # Raw PL/SQL method
            raw = method["raw_plsql"]
            if "RETURN" in raw.upper() and "SYS_REFCURSOR" not in raw.upper():
                lines.append(f"    PROCEDURE {name}({params}) IS")
            else:
                lines.append(f"    FUNCTION {name}({params}) RETURN SYS_REFCURSOR IS")
            lines.append(raw)
            if "RETURN" in raw.upper() and "SYS_REFCURSOR" not in raw.upper():
                lines.append(f"    END {name};")
            else:
                lines.append(f"    END {name};")
        else:
            # Transpiled method body
            lines.append(f"    PROCEDURE {name}({params}) IS")
            body = self._transpile_method_body(method["body_lines"])
            lines.append("    BEGIN")
            for bl in body:
                lines.append(f"        {bl}")
            lines.append(f"    END {name};")

        return lines

    def _transpile_method_body(self, body_lines: list) -> list:
        """Transpile Ruby-like method body into PL/SQL statements."""
        result = []
        for line in body_lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            # self.field = expr → direct column assignment (used in callbacks)
            m = re.match(r'self\.(\w+)\s*=\s*(.+)', stripped)
            if m:
                field = m.group(1)
                expr = self._transpile_expr(m.group(2))
                result.append(f"p_params('{field}') := {expr};")
                continue

            # Generic expression
            result.append(self._transpile_expr(stripped) + ";")

        return result

    def _transpile_expr(self, expr: str) -> str:
        """Transpile a Ruby-like expression to PL/SQL."""
        # lower(...) → LOWER(...)
        expr = re.sub(r'\blower\(', 'LOWER(', expr)
        expr = re.sub(r'\bupper\(', 'UPPER(', expr)
        expr = re.sub(r'\breplace\(', 'REPLACE(', expr)
        expr = re.sub(r'\btrim\(', 'TRIM(', expr)
        expr = re.sub(r'\blength\(', 'LENGTH(', expr)
        # self.field → p_params('field')
        expr = re.sub(r'self\.(\w+)', r"p_params('\1')", expr)
        return expr

    def _emit_callbacks(self, lines: list, callback_type: str, extra_indent: str = ""):
        for cb in self.callbacks.get(callback_type, []):
            lines.append(f"        {extra_indent}{cb}(p_params);")

    def _method_params_spec(self, method: dict) -> str:
        if not method["params"]:
            return ""
        parts = []
        for p in method["params"]:
            # Simple type inference
            if p.startswith("p_") or p.endswith("_id"):
                parts.append(f"{p} IN NUMBER")
            elif p.endswith("_date"):
                parts.append(f"{p} IN DATE")
            else:
                parts.append(f"{p} IN VARCHAR2 DEFAULT NULL")
        return ", ".join(parts)

    # ================================================================
    # Utilities
    # ================================================================

    @staticmethod
    def _to_snake(name: str) -> str:
        """CamelCase → snake_case"""
        s = re.sub(r'([A-Z])', r'_\1', name).lower().lstrip('_')
        return s
