"""
Routes Transpiler: routes DSL → PL/SQL

Example input:
    routes do
      root "home#index"

      resources :posts do
        resources :comments, only: [:create, :destroy]
      end

      get  "/about"   => "pages#about"
      post "/contact" => "pages#contact"

      namespace :api do
        resources :posts, format: :json
      end
    end
"""

import re
from .parser_utils import (
    parse_symbol, parse_symbol_list, parse_hash_opts, ParseError
)


class RoutesTranspiler:
    def __init__(self, source: str, filename: str = "<unknown>"):
        self.source = source
        self.filename = filename
        self.lines = source.split("\n")
        self.statements = []
        self.module_name = "hinoki"
        self.current_namespace = ""

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

            # routes "module_name" do  or  routes do
            m = re.match(r'^routes\s*(?:"(\w+)")?\s*do', line)
            if m:
                if m.group(1):
                    self.module_name = m.group(1)
                i += 1
                continue

            # root "controller#action"
            m = re.match(r'^root\s+"(\w+)#(\w+)"', line)
            if m:
                ctrl = self._namespaced_ctrl(m.group(1))
                self.statements.append(
                    f"hinoki_router.root('{ctrl}_controller', '{m.group(2)}');")
                i += 1
                continue

            # resources :name, opts  /  resources :name do ... end
            m = re.match(r'^resources\s+:(\w+)(.*)', line)
            if m:
                name = m.group(1)
                rest = m.group(2).strip()

                # Check if block follows (do)
                if rest.endswith("do") or (rest.rstrip(",").endswith("do")):
                    opts_str = rest[:-2].rstrip().rstrip(",")
                    opts = parse_hash_opts(opts_str) if opts_str.strip() else {}
                    self._emit_resources(name, opts)
                    # Process nested block
                    i += 1
                    while i < len(self.lines) and self.lines[i].strip() != "end":
                        # Could be nested resources
                        nested = self.lines[i].strip()
                        nm = re.match(r'^resources\s+:(\w+)(.*)', nested)
                        if nm:
                            nested_name = nm.group(1)
                            nested_opts = parse_hash_opts(nm.group(2)) if nm.group(2).strip() else {}
                            # Nested resource: /parent/:parent_id/child
                            self._emit_nested_resources(name, nested_name, nested_opts)
                        i += 1
                    i += 1  # skip 'end'
                    continue
                else:
                    opts = parse_hash_opts(rest) if rest.strip() else {}
                    self._emit_resources(name, opts)
                    i += 1
                    continue

            # get/post/put/delete/patch "path" => "controller#action"
            m = re.match(r'^(get|post|put|delete|patch)\s+"([^"]+)"\s*=>\s*"(\w+)#(\w+)"', line)
            if m:
                method = m.group(1).upper()
                path = self._namespaced_path(m.group(2))
                ctrl = self._namespaced_ctrl(m.group(3))
                action = m.group(4)
                method_call = "delete_route" if method == "DELETE" else method.lower()
                self.statements.append(
                    f"hinoki_router.{method_call}('{path}', '{ctrl}_controller', '{action}');")
                i += 1
                continue

            # namespace :name do ... end
            m = re.match(r'^namespace\s+:(\w+)\s+do', line)
            if m:
                prev_ns = self.current_namespace
                self.current_namespace = (self.current_namespace + "/" + m.group(1)
                                          if self.current_namespace else m.group(1))
                i += 1
                while i < len(self.lines) and self.lines[i].strip() != "end":
                    # Re-parse within namespace
                    ns_line = self.lines[i].strip()
                    # Handle resources inside namespace
                    nm = re.match(r'^resources\s+:(\w+)(.*)', ns_line)
                    if nm:
                        ns_name = nm.group(1)
                        ns_opts = parse_hash_opts(nm.group(2)) if nm.group(2).strip() else {}
                        self._emit_resources(ns_name, ns_opts)
                    # Handle individual routes
                    rm = re.match(r'^(get|post|put|delete|patch)\s+"([^"]+)"\s*=>\s*"(\w+)#(\w+)"',
                                  ns_line)
                    if rm:
                        method = rm.group(1).upper()
                        path = self._namespaced_path(rm.group(2))
                        ctrl = self._namespaced_ctrl(rm.group(3))
                        action = rm.group(4)
                        mc = "delete_route" if method == "DELETE" else method.lower()
                        self.statements.append(
                            f"hinoki_router.{mc}('{path}', '{ctrl}_controller', '{action}');")
                    i += 1
                self.current_namespace = prev_ns
                i += 1  # skip 'end'
                continue

            # end
            if line == "end":
                i += 1
                continue

            i += 1

    def _emit_resources(self, name: str, opts: dict):
        """Emit RESTful resource routes."""
        only = opts.get("only")
        except_actions = opts.get("except")
        ctrl = self._namespaced_ctrl(name)
        path_base = self._namespaced_path(f"/{name}")

        all_actions = {
            "index":   ("get",          path_base),
            "new":     ("get",          f"{path_base}/new"),
            "create":  ("post",         path_base),
            "show":    ("get",          f"{path_base}/:id"),
            "edit":    ("get",          f"{path_base}/:id/edit"),
            "update":  ("put",          f"{path_base}/:id"),
            "destroy": ("delete_route", f"{path_base}/:id"),
        }

        action_map = {
            "index":   "index_action",
            "new":     "new_form",
            "create":  "create_action",
            "show":    "show",
            "edit":    "edit_form",
            "update":  "update_action",
            "destroy": "delete_action",
        }

        for action_name, (method, path) in all_actions.items():
            if only and action_name not in only:
                continue
            if except_actions and action_name in except_actions:
                continue
            plsql_action = action_map[action_name]
            self.statements.append(
                f"hinoki_router.{method}('{path}', '{ctrl}_controller', '{plsql_action}');")

        # Also add POST routes for HTML form compatibility
        if not only or "update" in (only or []):
            if not except_actions or "update" not in except_actions:
                self.statements.append(
                    f"hinoki_router.post('{path_base}/:id', '{ctrl}_controller', 'update_action');")
        if not only or "destroy" in (only or []):
            if not except_actions or "destroy" not in except_actions:
                self.statements.append(
                    f"hinoki_router.post('{path_base}/:id/delete', '{ctrl}_controller', 'delete_action');")

    def _emit_nested_resources(self, parent: str, child: str, opts: dict):
        """Emit nested resource routes like /posts/:post_id/comments"""
        parent_path = self._namespaced_path(f"/{parent}/:id")
        ctrl = self._namespaced_ctrl(child)

        nested_actions = {
            "index":   ("get",          f"{parent_path}/{child}"),
            "create":  ("post",         f"{parent_path}/{child}"),
            "show":    ("get",          f"{parent_path}/{child}/:child_id"),
            "destroy": ("delete_route", f"{parent_path}/{child}/:child_id"),
        }

        action_map = {
            "index": "index_action",
            "create": "create_action",
            "show": "show",
            "destroy": "delete_action",
        }

        only = opts.get("only")
        for action_name, (method, path) in nested_actions.items():
            if only and action_name not in only:
                continue
            plsql_action = action_map[action_name]
            self.statements.append(
                f"hinoki_router.{method}('{path}', '{ctrl}_controller', '{plsql_action}');")

    def _namespaced_path(self, path: str) -> str:
        if self.current_namespace:
            return f"/{self.current_namespace}{path}"
        return path

    def _namespaced_ctrl(self, name: str) -> str:
        if self.current_namespace:
            return f"{self.current_namespace.replace('/', '_')}_{name}"
        return name

    def _generate(self) -> str:
        lines = []
        lines.append(f"-- Generated by Hinoki Transpiler from {self.filename}")
        lines.append(f"-- Routes for module: {self.module_name}")
        lines.append("BEGIN")

        for stmt in self.statements:
            lines.append(f"    {stmt}")

        lines.append("")
        lines.append(f"    hinoki_router.deploy_routes('{self.module_name}');")
        lines.append("END;")
        lines.append("/")

        return "\n".join(lines)
