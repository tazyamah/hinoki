"""
Migration Transpiler: migration DSL → PL/SQL

Example input:
    migration "create_posts" do
      create_table :posts do
        string  :title, null: false, limit: 500
        text    :body
        boolean :published, default: false
        integer :view_count, default: 0
        index   :published
        index   [:author, :published], unique: true
      end

      add_index :posts, :title
    end
"""

import re
from .parser_utils import (
    parse_symbol, parse_symbol_list, parse_hash_opts,
    extract_block, ParseError
)


# Column type mappings: DSL type → Oracle SQL type
TYPE_MAP = {
    "string":    lambda opts: f"VARCHAR2({opts.get('limit', 200)})",
    "text":      lambda opts: "CLOB",
    "integer":   lambda opts: f"NUMBER({opts.get('limit', 10)})",
    "number":    lambda opts: "NUMBER",
    "float":     lambda opts: "NUMBER(15,5)",
    "decimal":   lambda opts: f"NUMBER({opts.get('precision', 20)},{opts.get('scale', 8)})",
    "boolean":   lambda opts: "NUMBER(1)",
    "date":      lambda opts: "DATE",
    "datetime":  lambda opts: "TIMESTAMP",
    "timestamp": lambda opts: "TIMESTAMP",
    "binary":    lambda opts: "BLOB",
    "blob":      lambda opts: "BLOB",
    "references": lambda opts: "NUMBER",
}


class MigrationTranspiler:
    def __init__(self, source: str, filename: str = "<unknown>"):
        self.source = source
        self.filename = filename
        self.lines = source.split("\n")
        self.migration_name = ""
        self.statements = []  # List of PL/SQL statements for the UP migration
        self.down_statements = []  # DOWN migration

    def transpile(self) -> str:
        self._parse()
        return self._generate()

    def _parse(self):
        i = 0
        while i < len(self.lines):
            line = self.lines[i].strip()

            if not line or line.startswith("#"):
                i += 1
                continue

            # migration "name" do
            m = re.match(r'^migration\s+"([^"]+)"\s+do', line)
            if m:
                self.migration_name = m.group(1)
                i += 1
                continue

            # create_table :name do ... end
            m = re.match(r'^create_table\s+:(\w+)\s+do', line)
            if m:
                table_name = m.group(1)
                # Collect lines until matching end
                block_lines = []
                i += 1
                while i < len(self.lines) and self.lines[i].strip() != "end":
                    block_lines.append(self.lines[i])
                    i += 1
                i += 1  # skip 'end'
                self._parse_create_table(table_name, block_lines)
                continue

            # drop_table :name
            m = re.match(r'^drop_table\s+:(\w+)', line)
            if m:
                self.statements.append(f"hinoki_migrate.drop_table('{m.group(1)}');")
                i += 1
                continue

            # add_column :table, :column, :type, opts
            m = re.match(r'^add_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)(.*)', line)
            if m:
                table = m.group(1)
                col = m.group(2)
                type_name = m.group(3)
                opts = parse_hash_opts(m.group(4)) if m.group(4).strip() else {}
                oracle_type = TYPE_MAP.get(type_name, lambda o: type_name.upper())(opts)
                default = f"'{opts['default']}'" if "default" in opts else "NULL"
                self.statements.append(
                    f"hinoki_migrate.add_column('{table}', '{col}', '{oracle_type}', {default});")
                i += 1
                continue

            # remove_column :table, :column
            m = re.match(r'^remove_column\s+:(\w+)\s*,\s*:(\w+)', line)
            if m:
                self.statements.append(
                    f"hinoki_migrate.remove_column('{m.group(1)}', '{m.group(2)}');")
                i += 1
                continue

            # change_column :table, :column, :type
            m = re.match(r'^change_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)', line)
            if m:
                type_name = m.group(3)
                oracle_type = TYPE_MAP.get(type_name, lambda o: type_name.upper())({})
                self.statements.append(
                    f"hinoki_migrate.change_column('{m.group(1)}', '{m.group(2)}', '{oracle_type}');")
                i += 1
                continue

            # add_index :table, :column(s), opts
            m = re.match(r'^add_index\s+:(\w+)\s*,\s*(.+)', line)
            if m:
                table = m.group(1)
                rest = m.group(2).strip()
                cols_match = re.match(r':(\w+)(.*)', rest)
                arr_match = re.match(r'\[([^\]]+)\](.*)', rest)

                if arr_match:
                    cols = ", ".join(parse_symbol_list(arr_match.group(1)))
                    opts = parse_hash_opts(arr_match.group(2)) if arr_match.group(2) else {}
                elif cols_match:
                    cols = cols_match.group(1)
                    opts = parse_hash_opts(cols_match.group(2)) if cols_match.group(2) else {}
                else:
                    cols = rest
                    opts = {}

                unique = "TRUE" if opts.get("unique") else "FALSE"
                name = f"'{opts['name']}'" if "name" in opts else "NULL"
                self.statements.append(
                    f"hinoki_migrate.add_index('{table}', '{cols}', {unique}, {name});")
                i += 1
                continue

            # add_foreign_key :from_table, :column, :to_table
            m = re.match(r'^add_foreign_key\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)', line)
            if m:
                self.statements.append(
                    f"hinoki_migrate.add_foreign_key('{m.group(1)}', '{m.group(2)}', '{m.group(3)}');")
                i += 1
                continue

            # remove_index :name
            m = re.match(r'^remove_index\s+[:\']?(\w+)', line)
            if m:
                self.statements.append(f"hinoki_migrate.remove_index('{m.group(1)}');")
                i += 1
                continue

            # execute "raw SQL"
            m = re.match(r'^execute\s+"([^"]+)"', line)
            if m:
                self.statements.append(f"hinoki_migrate.execute_sql('{m.group(1)}');")
                i += 1
                continue

            # end (migration block)
            if line == "end":
                i += 1
                continue

            i += 1

    def _parse_create_table(self, table_name: str, block_lines: list):
        """Parse column definitions inside create_table block."""
        columns = []
        indexes = []
        foreign_keys = []

        for line in block_lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            # index :column or index [:col1, :col2]
            m = re.match(r'^index\s+(.+)', stripped)
            if m:
                rest = m.group(1).strip()
                arr_match = re.match(r'\[([^\]]+)\](.*)', rest)
                if arr_match:
                    cols = ", ".join(parse_symbol_list(arr_match.group(1)))
                    opts = parse_hash_opts(arr_match.group(2)) if arr_match.group(2).strip() else {}
                else:
                    parts = rest.split(",", 1)
                    cols = parse_symbol(parts[0])
                    opts = parse_hash_opts(parts[1]) if len(parts) > 1 else {}
                indexes.append({"columns": cols, "unique": opts.get("unique", False)})
                continue

            # references :other_table
            m = re.match(r'^references\s+:(\w+)(.*)', stripped)
            if m:
                ref_table = m.group(1)
                opts = parse_hash_opts(m.group(2)) if m.group(2).strip() else {}
                fk_col = opts.get("foreign_key", ref_table.rstrip("s") + "_id"
                                  if not ref_table.endswith("_id") else ref_table)
                columns.append(f"{fk_col} NUMBER NOT NULL")
                foreign_keys.append({"column": fk_col, "ref_table": ref_table})
                continue

            # type :column_name, opts
            m = re.match(r'^(\w+)\s+:(\w+)(.*)', stripped)
            if m:
                type_name = m.group(1)
                col_name = m.group(2)
                opts = parse_hash_opts(m.group(3)) if m.group(3).strip() else {}

                if type_name not in TYPE_MAP:
                    continue

                oracle_type = TYPE_MAP[type_name](opts)
                col_def = f"{col_name} {oracle_type}"

                if opts.get("null") is False:
                    col_def += " NOT NULL"

                if "default" in opts:
                    default_val = opts["default"]
                    if isinstance(default_val, bool):
                        col_def += f" DEFAULT {1 if default_val else 0}"
                    elif isinstance(default_val, (int, float)):
                        col_def += f" DEFAULT {default_val}"
                    else:
                        col_def += f" DEFAULT '{default_val}'"

                columns.append(col_def)

        # Generate CREATE TABLE statement
        col_defs = ", ".join(columns)
        self.statements.append(f"hinoki_migrate.create_table('{table_name}', '{col_defs}');")

        # Generate indexes
        for idx in indexes:
            unique = "TRUE" if idx["unique"] else "FALSE"
            self.statements.append(
                f"hinoki_migrate.add_index('{table_name}', '{idx['columns']}', {unique});")

        # Generate foreign keys
        for fk in foreign_keys:
            self.statements.append(
                f"hinoki_migrate.add_foreign_key('{table_name}', '{fk['column']}', '{fk['ref_table']}');")

        # DOWN migration
        self.down_statements.append(f"hinoki_migrate.drop_table('{table_name}');")

    def _generate(self) -> str:
        lines = []
        lines.append(f"-- Generated by Hinoki Transpiler from {self.filename}")
        lines.append(f"-- Migration: {self.migration_name}")
        lines.append("BEGIN")

        for stmt in self.statements:
            lines.append(f"    {stmt}")

        lines.append("END;")
        lines.append("/")

        # Also generate DOWN migration as a comment block
        if self.down_statements:
            lines.append("")
            lines.append("-- === ROLLBACK (DOWN) ===")
            lines.append("-- BEGIN")
            for stmt in self.down_statements:
                lines.append(f"--     {stmt}")
            lines.append("-- END;")
            lines.append("-- /")

        return "\n".join(lines)
