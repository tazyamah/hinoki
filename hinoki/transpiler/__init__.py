"""
Hinoki Transpiler: .hk (Ruby-like DSL) → PL/SQL

Converts .hk files into valid PL/SQL packages that run on
OCI Autonomous Database via ORDS.
"""

from pathlib import Path
from .model_gen import ModelTranspiler
from .controller_gen import ControllerTranspiler
from .migration_gen import MigrationTranspiler
from .routes_gen import RoutesTranspiler


def detect_type(source: str) -> str:
    """Detect .hk file type from its content."""
    stripped = source.strip()
    for line in stripped.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("model "):
            return "model"
        if line.startswith("controller "):
            return "controller"
        if line.startswith("migration "):
            return "migration"
        if line.startswith("routes"):
            return "routes"
        break
    raise ValueError("Unknown .hk file type. Must start with: model, controller, migration, or routes")


def transpile(source: str, filename: str = "<unknown>") -> str:
    """Transpile a .hk source string into PL/SQL.

    Args:
        source: The .hk file content
        filename: Source filename (for error messages)

    Returns:
        Generated PL/SQL code as a string
    """
    file_type = detect_type(source)

    transpilers = {
        "model": ModelTranspiler,
        "controller": ControllerTranspiler,
        "migration": MigrationTranspiler,
        "routes": RoutesTranspiler,
    }

    t = transpilers[file_type](source, filename)
    return t.transpile()


def transpile_file(filepath: Path) -> str:
    """Transpile a .hk file to PL/SQL.

    Args:
        filepath: Path to the .hk file

    Returns:
        Generated PL/SQL code
    """
    source = filepath.read_text(encoding="utf-8")
    return transpile(source, str(filepath))


def is_hk_file(filepath: Path) -> bool:
    """Check if a file is a .hk DSL file."""
    return filepath.suffix == ".hk"
