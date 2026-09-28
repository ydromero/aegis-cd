#!/bin/bash
# =============================================================================
# orquestador — Flujo quirúrgico multi-agente (Pi CLI)
# Fases: Analista (triage + diagnóstico) -> Arquitecto (plan) -> Ejecutor -> QA
#
# Bash decide el orden; cada fase corre como un proceso `pi` aislado con las
# herramientas declaradas en el frontmatter de su agente (recortadas por el
# arnés según los opt-in). El modelo NO decide si delega o no.
#
# Uso:  orquestador --help
#
# Configuración (prioridad: variables de entorno > .pi/project.env > defaults):
#   .pi/project.env  archivo CLAVE=valor (SIN comandos: no se evalúa nada).
#   Claves: EXCLUDES MAX_DELETED_LINES PIKIT_EXT_DIR PROTECTED_PATHS_CONFIG
#           NO_CONTEXT_FILES y {ANALYST,ARCHITECT,EXECUTOR,QA}_{MODEL,THINKING}
#   EXCLUDES = rutas (separadas por espacios) fuera de la auditoría de alcance.
#   AGENTS_DIR (solo entorno) fuerza una carpeta de agentes.
#   Búsqueda de agentes, por archivo: $AGENTS_DIR -> <repo>/.pi/agents ->
#   ~/.pi/agent/agents -> agents/ incluidos en esta herramienta.
#
# Códigos de salida:
#   0 ok / QA PASS | 1 uso, fase o seguridad | 2 HALT (analista, arquitecto o ejecutor)
#   3 formato inesperado | 4 QA FAIL | 5 QA MANUAL_REQUIRED
# =============================================================================

set -u

# --- ubicación de la herramienta (resuelve symlinks) --------------------------
_src="$0"
while [ -h "$_src" ]; do
  _d=$(cd "$(dirname "$_src")" && pwd)
  _src=$(readlink "$_src")
  case "$_src" in /*) ;; *) _src="$_d/$_src" ;; esac
done
TOOL_DIR=$(cd "$(dirname "$_src")/.." && pwd)
TOOL_VERSION=$(cat "$TOOL_DIR/VERSION" 2>/dev/null || echo "dev")

usage() {
  echo "Uso:"
  echo "  $0 \"Descripción del Issue\" [ID]        Fases 1 y 2 (Gate 1 y Gate 2)"
  echo "  $0 --plan ID                           Retoma la Fase 2 tras un Gate 1"
  echo "  $0 --approve ID                        Aprueba y sella el plan (SHA-256, solo lectura)"
  echo "  $0 --reseal ID                         Re-sella un plan aprobado que cambió (muestra diff)"
  echo "  $0 --execute ID [--allow-write] [--manual]"
  echo "                                         Ejecuta el plan sellado (el Ejecutor NO recibe 'write'"
  echo "                                         salvo --allow-write; --manual = sesión interactiva)"
  echo "  $0 --qa ID [--allow-bash]              Auditoría de alcance + QA (QA NO recibe 'bash' salvo --allow-bash)"
  echo "  $0 --init [perfil]                     Crea .pi/project.env y .pi/stack-profile.md (generic|laravel)"
  echo "  $0 --version | --help"
}

case "${1:-}" in
  --version|-V) echo "orquestador $TOOL_VERSION"; exit 0 ;;
  --help|-h)    usage; exit 0 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "❌ Ejecuta este script dentro de un repositorio git."
  exit 1
}
cd "$ROOT" || exit 1

# -----------------------------------------------------------------------------
# RUTA: --init (crea la configuración del proyecto a partir de un perfil)
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--init" ]; then
  PROFILE="${2:-generic}"
  if ! [[ "$PROFILE" =~ ^[a-z0-9_-]+$ ]] || [ ! -d "$TOOL_DIR/profiles/$PROFILE" ]; then
    echo "❌ Perfil desconocido: $PROFILE. Disponibles: $(ls "$TOOL_DIR/profiles" 2>/dev/null | tr '\n' ' ')"
    exit 1
  fi
  mkdir -p .pi
  for f in project.env stack-profile.md; do
    if [ -e ".pi/$f" ]; then
      echo "↩︎  .pi/$f ya existe; no se sobrescribe."
    else
      cp "$TOOL_DIR/profiles/$PROFILE/$f" ".pi/$f"
      echo "✅ .pi/$f creado (perfil $PROFILE)."
    fi
  done
  if ! grep -qxF '.pi/handoffs/' .gitignore 2>/dev/null; then
    if [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore)" ]; then echo >> .gitignore; fi
    echo '.pi/handoffs/' >> .gitignore
    echo "✅ .gitignore: se añadió .pi/handoffs/"
  fi
  echo "👉 Versiona .pi/project.env y .pi/stack-profile.md (git add + commit): se auditan como cualquier archivo."
  exit 0
fi

# --- configuración del proyecto (.pi/project.env): solo CLAVE=valor, sin eval --
PROJECT_CONFIG=".pi/project.env"
CONFIG_KEYS=" EXCLUDES MAX_DELETED_LINES PIKIT_EXT_DIR PROTECTED_PATHS_CONFIG NO_CONTEXT_FILES ANALYST_MODEL ARCHITECT_MODEL EXECUTOR_MODEL QA_MODEL ANALYST_THINKING ARCHITECT_THINKING EXECUTOR_THINKING QA_THINKING "

load_project_config() {
  local file="$1" line key val n=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line="${line%$'\r'}"
    case "$line" in ''|'#'*|[[:space:]]*'#'*|[[:space:]]) continue ;; esac
    if ! [[ "$line" =~ ^[A-Z_]+= ]]; then
      echo "⚠️  $file:$n ignorada (formato esperado CLAVE=valor)."
      continue
    fi
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$CONFIG_KEYS" != *" $key "* ]]; then
      echo "⚠️  $file:$n clave no permitida: $key (ignorada)."
      continue
    fi
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    # el entorno tiene prioridad sobre el archivo; nada se evalúa
    if [ -z "${!key:-}" ]; then printf -v "$key" '%s' "$val"; fi
  done < "$file"
}
load_project_config "$PROJECT_CONFIG"

AGENTS_DIR="${AGENTS_DIR:-}"
HANDOFF_DIR=".pi/handoffs"
PIKIT_EXT_DIR="${PIKIT_EXT_DIR:-$HOME/.pi/agent/npm/node_modules/@adrianapan/pikit/agent/extensions}"
PROTECTED_PATHS_CONFIG="${PROTECTED_PATHS_CONFIG:-$HOME/.pi/agent/configs/protected-paths.json}"
MAX_DELETED_LINES="${MAX_DELETED_LINES:-40}"
EXCLUDES="${EXCLUDES:-}"

ANALYST_MODEL="${ANALYST_MODEL:-}"
ARCHITECT_MODEL="${ARCHITECT_MODEL:-}"
EXECUTOR_MODEL="${EXECUTOR_MODEL:-}"
QA_MODEL="${QA_MODEL:-}"
ANALYST_THINKING="${ANALYST_THINKING:-}"
ARCHITECT_THINKING="${ARCHITECT_THINKING:-}"
EXECUTOR_THINKING="${EXECUTOR_THINKING:-}"
QA_THINKING="${QA_THINKING:-}"

# Patrones anclados (evitan falsos positivos en el cuerpo del plan)
RE_APPROVED='^\* \*\*Aprobado por:\*\* Humano ✅'
RE_PENDING='^\* \*\*Aprobado por:\*\* Humano ⬜'
RE_HALT='^#+ HALT - FILE NOT FOUND'

# Rutas fuera de la auditoría: SOLO los handoffs (volátiles, en .gitignore) más las
# EXCLUDES del proyecto. .pi/project.env, .pi/stack-profile.md y .pi/agents/ SÍ se auditan.
EXCL_PATHS=(".pi/handoffs")
read -r -a _ex_arr <<< "$EXCLUDES"
for _p in "${_ex_arr[@]+"${_ex_arr[@]}"}"; do
  case "$_p" in
    /*|*..*) echo "❌ EXCLUDES inválido: '$_p' (sin rutas absolutas ni '..')."; exit 1 ;;
  esac
  EXCL_PATHS+=("${_p%/}")
done
EXCLUDES_PS=()
RE_EXCLUDED=""
for _p in "${EXCL_PATHS[@]}"; do
  EXCLUDES_PS+=(":(exclude)$_p")
  _esc=$(printf '%s' "$_p" | sed 's/[][\.^$*+?(){}|]/\\&/g')
  RE_EXCLUDED="${RE_EXCLUDED:+$RE_EXCLUDED|}$_esc"
done
RE_EXCLUDED="^($RE_EXCLUDED)/"

mkdir -p "$HANDOFF_DIR"
if ! git check-ignore -q "$HANDOFF_DIR/x" 2>/dev/null; then
  echo "⚠️  $HANDOFF_DIR no está en .gitignore: los handoffs podrían acabar en un commit. Ejecuta: $0 --init"
fi

# -----------------------------------------------------------------------------
# Utilidades
# -----------------------------------------------------------------------------

need_id() {
  if [ -z "${1:-}" ] || ! [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "❌ Debes indicar un ID válido (letras, números, punto, guion, guion bajo)."
    usage
    exit 1
  fi
}

confirm() {
  local a
  read -r -p "$1 [s/N] " a || a=""
  [[ "$a" =~ ^[sSyY]$ ]]
}

log_decision() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >> "$HANDOFF_DIR/$1-decisions.log"
}

# SHA-256 portable (Linux: sha256sum / macOS: shasum)
sha_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
sha_stdin() { sha_file | awk '{print $1}'; }

# Huella de archivos protegidos: .env* (suelen estar en .gitignore: git no los ve) y la
# configuración/prompts del propio flujo. Se compara antes y después de Ejecutor y QA.
guard_fingerprint() {
  local f
  for f in .env .env.* .pi/project.env .pi/stack-profile.md .pi/agents/*; do
    [ -f "$f" ] && sha_file "$f"
  done 2>/dev/null | sha_stdin
}

# Quita una herramienta de una lista separada por comas (a,b,c)
strip_tool() { printf '%s' "$1" | tr ',' '\n' | grep -vx "$2" | paste -sd, -; }

# (EXCLUDES_PS y RE_EXCLUDED se construyen arriba a partir de .pi/project.env)

# Archivos nuevos sin trackear (filtrados en el origen: sirven a changed_files y a tree_snapshot)
changed_untracked() { git ls-files --others --exclude-standard | grep -vE "$RE_EXCLUDED"; }

# Archivos tocados en el árbol de trabajo (ordenados)
changed_files() {
  {
    git diff --name-only -- . "${EXCLUDES_PS[@]}"
    git diff --cached --name-only -- . "${EXCLUDES_PS[@]}"
    changed_untracked
  } | sort -u
}

# Huella del CONTENIDO del árbol de trabajo (detecta ediciones sobre archivos ya modificados)
tree_snapshot() {
  {
    git diff -- . "${EXCLUDES_PS[@]}"
    git diff --cached -- . "${EXCLUDES_PS[@]}"
    changed_untracked | while IFS= read -r f; do
      printf '%s:' "$f"
      sha_stdin < "$f"
    done
  } | sha_stdin
}

# Rutas declaradas como Target en el plan, normalizadas a relativas a la raíz del repo
# (un LLM puede escribir la ruta absoluta del cwd o un prefijo ./)
plan_targets() {
  grep -F '**Target:**' "$1" | grep -oE '`[^`]+`' | tr -d '`' | while IFS= read -r p; do
    p="${p#"$ROOT"/}"
    p="${p#./}"
    p="${p%%:[0-9]*}"   # tolera app/Foo.php:12-20
    printf '%s\n' "$p"
  done | sort -u
}

plan_template_ok() {
  grep -qE "$RE_PENDING" "$1" && grep -q "pending human approval" "$1"
}

# Sella el plan: hash SHA-256, copia de lo aprobado (para poder ver diferencias
# en --reseal) y lo deja de solo lectura para evitar ediciones accidentales.
seal_plan() {
  local file="$1"
  chmod u+w "$file" 2>/dev/null
  rm -f "${file}.sha256"
  sha_file "$file" > "${file}.sha256"
  rm -f "${file}.approved"
  cp "$file" "${file}.approved"
  chmod a-w "$file" "${file}.approved" "${file}.sha256"
}

# Estampa la aprobación humana (fecha) y sella. Falla si no pudo aprobar.
approve_plan() {
  local file="$1" ts tmp
  if grep -qE "$RE_HALT" "$file"; then
    echo "❌ $file es un HALT, no un plan. Nada que aprobar."
    return 1
  fi
  if ! grep -qE "$RE_PENDING" "$file"; then
    echo "❌ $file no está pendiente de aprobación (¿ya aprobado o formato inesperado?)."
    return 1
  fi
  ts=$(date '+%Y-%m-%d %H:%M')
  tmp=$(mktemp)
  sed -E "s/^(\* \*\*Aprobado por:\*\*) Humano .*/\1 Humano ✅ ($ts)/; s/^(\* \*\*Current State:\*\*) .*/\1 🟠 Plan approved, ready for execution/" "$file" > "$tmp" \
    && mv "$tmp" "$file"
  rm -f "$tmp"
  if ! grep -qE "$RE_APPROVED" "$file"; then
    echo "❌ No se pudo estampar la aprobación en $file. Revisa el formato del plan."
    return 1
  fi
  seal_plan "$file"
  return 0
}

# Verifica aprobación humana + integridad del plan (SHA-256)
verify_plan_seal() {
  local plan="$1" id
  id=$(basename "$plan" -plan.md)
  if ! grep -qE "$RE_APPROVED" "$plan"; then
    echo "❌ SEGURIDAD: $plan no tiene aprobación humana registrada."
    echo "   Usa: $0 --approve $id"
    return 1
  fi
  if [ ! -f "${plan}.sha256" ]; then
    echo "❌ SEGURIDAD: falta la firma ${plan}.sha256."
    echo "   Si el plan es legítimo, revísalo y usa: $0 --reseal $id"
    return 1
  fi
  if ! sha_file -c "${plan}.sha256" >/dev/null 2>&1; then
    echo "🚨 ALERTA CRÍTICA: $plan fue modificado después de la aprobación (SHA-256 no coincide)."
    echo "   Si el cambio fue intencional (o lo hizo el editor al guardar): $0 --reseal $id"
    return 1
  fi
  return 0
}

# Guardarraíl de lectura (.env, credenciales): solo si está configurado
PP_EXT=""
if [ -f "$PIKIT_EXT_DIR/protected-paths/index.ts" ] && [ -f "$PROTECTED_PATHS_CONFIG" ]; then
  if command -v realpath >/dev/null 2>&1; then
    PP_EXT="$(realpath "$PIKIT_EXT_DIR/protected-paths/index.ts")"
  else
    PP_EXT="$PIKIT_EXT_DIR/protected-paths/index.ts"
  fi
fi

# Búsqueda por archivo: $AGENTS_DIR -> .pi/agents (proyecto) -> ~/.pi/agent/agents -> agents/ incluidos
resolve_agent() {
  local name="$1" d
  for d in "$AGENTS_DIR" "$ROOT/.pi/agents" "$HOME/.pi/agent/agents" "$TOOL_DIR/agents"; do
    if [ -n "$d" ] && [ -f "$d/$name.md" ]; then printf '%s' "$d/$name.md"; return 0; fi
  done
  return 1
}

# Lanza una fase como proceso `pi` aislado.
# $1 agente  $2 tarea  $3 archivo de salida  $4 thinking  $5 modelo
run_phase() {
  local agent="$1" task="$2" out="$3" thinking="$4" model="$5"
  local file body tools code

  file=$(resolve_agent "$agent") || {
    echo "❌ No encuentro el agente '$agent.md' en la cadena de búsqueda (AGENTS_DIR, .pi/agents, ~/.pi/agent/agents, agents/)."
    return 1
  }

  # Las herramientas salen del frontmatter (única fuente de verdad).
  tools=$(sed -n 's/^tools:[[:space:]]*\[\(.*\)\].*/\1/p' "$file" | tr -d ' ')
  if [ -z "$tools" ]; then
    echo "❌ $agent.md no declara 'tools: [...]' en una línea: no lanzo la fase sin restricción."
    return 1
  fi

  # El prompt no es un firewall: las herramientas peligrosas se quitan aquí salvo opt-in explícito.
  case "$agent" in
    qa)       [ "${QA_ALLOW_BASH:-0}" = "1" ]        || tools=$(strip_tool "$tools" bash) ;;
    executor) [ "${EXECUTOR_ALLOW_WRITE:-0}" = "1" ] || tools=$(strip_tool "$tools" write) ;;
  esac
  if [ -z "$tools" ]; then echo "❌ $agent se quedó sin herramientas tras el recorte."; return 1; fi
  echo "   🧩 $agent: $file"
  echo "   🔧 $agent: tools=$tools"

  # El cuerpo del agente (sin frontmatter) es su system prompt.
  body=$(mktemp)
  awk '/^---[[:space:]]*$/ && c<2 {c++; next} c>=2' "$file" > "$body"

  local args=(-p --no-session --tools "$tools" --no-extensions --no-skills --append-system-prompt "$body")
  if [ -n "$thinking" ]; then args+=(--thinking "$thinking"); fi
  if [ -n "$model" ]; then args+=(--model "$model"); fi
  if [ "${NO_CONTEXT_FILES:-0}" = "1" ]; then args+=(--no-context-files); fi
  if [ -n "$PP_EXT" ]; then args+=(-e "$PP_EXT"); fi

  pi "${args[@]}" "$task" > "$out" 2> "$out.err" < /dev/null
  code=$?
  rm -f "$body"

  if [ $code -ne 0 ] || [ ! -s "$out" ]; then
    echo "❌ La fase '$agent' falló (código $code). Últimas líneas de stderr:"
    tail -n 8 "$out.err"
    return 1
  fi
  if [ ! -s "$out.err" ]; then rm -f "$out.err"; fi
  return 0
}

# Fase 2 (Arquitecto) + Gate 2. Compartida por el flujo normal y --plan.
run_architect() {
  local id="$1"
  local analyst_out="$HANDOFF_DIR/${id}-analyst.md"
  local plan_out="$HANDOFF_DIR/${id}-plan.md"

  if [ -f "$plan_out" ]; then
    if ! confirm "⚠️  Ya existe $plan_out. ¿Regenerarlo? (se invalida cualquier aprobación previa)"; then
      echo "Cancelado. No se modificó nada."
      exit 0
    fi
    rm -f "$plan_out" "${plan_out}.sha256" "${plan_out}.approved"
  fi

  echo "⏳ Fase 2: Arquitecto (diseño del plan)..."
  run_phase architect "Draft the execution plan for the Analyst Handoff stored at: $analyst_out
Read that file first. Then verify every file and line it references with your tools before drafting the plan." \
    "$plan_out" "$ARCHITECT_THINKING" "$ARCHITECT_MODEL" || exit 1

  if grep -qE "$RE_HALT" "$plan_out"; then
    echo "🛑 El Arquitecto no pudo confirmar los archivos. Revisa $plan_out."
    exit 2
  fi
  if ! plan_template_ok "$plan_out"; then
    echo "⚠️  El plan no sigue la plantilla de aprobación (¿el Arquitecto se auto-aprobó o cambió el formato?). Revisa $plan_out."
    exit 3
  fi

  echo "======================================================"
  echo "✅ Plan generado."
  echo "📄 Diagnóstico: $analyst_out"
  echo "📄 Plan:        $plan_out"
  echo "------------------------------------------------------"
  echo "🚧 PUNTO DE CONTROL HUMANO (Gate 2): revisa el plan antes de aprobar."
  if confirm "¿Apruebas el plan?"; then
    approve_plan "$plan_out" || exit 1
    log_decision "$id" "Gate 2: plan aprobado y sellado"
    echo "✅ Plan aprobado y sellado (SHA-256). Para ejecutarlo: $0 --execute $id"
  else
    log_decision "$id" "Gate 2: plan NO aprobado (pendiente)"
    echo "Plan pendiente. Cuando lo apruebes: $0 --approve $id"
  fi
  echo "======================================================"
}

# -----------------------------------------------------------------------------
# RUTA: --approve
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--approve" ]; then
  need_id "${2:-}"
  PLAN_FILE="$HANDOFF_DIR/${2}-plan.md"
  if [ ! -f "$PLAN_FILE" ]; then echo "❌ No existe $PLAN_FILE"; exit 1; fi
  approve_plan "$PLAN_FILE" || exit 1
  log_decision "$2" "Plan aprobado y sellado vía --approve"
  echo "✅ Plan aprobado y sellado: $PLAN_FILE"
  echo "🔒 SHA-256 guardado en ${PLAN_FILE}.sha256"
  exit 0
fi

# -----------------------------------------------------------------------------
# RUTA: --reseal (re-sellar un plan aprobado que cambió; muestra las diferencias)
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--reseal" ]; then
  need_id "${2:-}"
  PLAN_FILE="$HANDOFF_DIR/${2}-plan.md"
  if [ ! -f "$PLAN_FILE" ]; then echo "❌ No existe $PLAN_FILE"; exit 1; fi
  if ! grep -qE "$RE_APPROVED" "$PLAN_FILE"; then
    echo "❌ El plan no figura como aprobado. Usa: $0 --approve $2"
    exit 1
  fi
  if verify_plan_seal "$PLAN_FILE" >/dev/null 2>&1; then
    echo "✅ El sello ya es válido; no hay nada que re-sellar."
    exit 0
  fi
  echo "⚠️  El plan cambió después de la aprobación."
  if [ -f "${PLAN_FILE}.approved" ]; then
    echo "------ Diferencias respecto a la versión aprobada ------"
    diff -u "${PLAN_FILE}.approved" "$PLAN_FILE" || true
    echo "--------------------------------------------------------"
  else
    echo "(no hay copia aprobada con la que comparar)"
  fi
  if ! confirm "¿Re-sellar el plan con estos cambios? (si cambió el fondo, revísalo de nuevo)"; then
    echo "Cancelado. El plan sigue sin sello válido."
    exit 1
  fi
  seal_plan "$PLAN_FILE"
  log_decision "$2" "Plan re-sellado tras modificación manual"
  echo "🔒 Plan re-sellado: $PLAN_FILE"
  exit 0
fi

# -----------------------------------------------------------------------------
# RUTA: --plan (retomar Fase 2 tras Gate 1)
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--plan" ]; then
  need_id "${2:-}"
  if [ ! -f "$HANDOFF_DIR/${2}-analyst.md" ]; then
    echo "❌ No existe el diagnóstico: $HANDOFF_DIR/${2}-analyst.md"
    exit 1
  fi
  log_decision "$2" "Fase 2 retomada vía --plan"
  run_architect "$2"
  exit 0
fi

# -----------------------------------------------------------------------------
# RUTA: --execute (verifica sello y lanza/prepara la ejecución)
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--execute" ]; then
  need_id "${2:-}"
  ISSUE_ID="$2"
  PLAN_FILE="$HANDOFF_DIR/${ISSUE_ID}-plan.md"
  if [ ! -f "$PLAN_FILE" ]; then echo "❌ No existe el plan: $PLAN_FILE"; exit 1; fi

  verify_plan_seal "$PLAN_FILE" || exit 1

  EXEC_MANUAL=0
  for _f in "${@:3}"; do
    case "$_f" in
      --allow-write) EXECUTOR_ALLOW_WRITE=1 ;;
      --manual)      EXEC_MANUAL=1 ;;
      *) echo "❌ Opción desconocida para --execute: $_f"; exit 1 ;;
    esac
  done

  # Árbol limpio: así todo cambio posterior es atribuible al Ejecutor.
  if [ -n "$(git status --porcelain -- . "${EXCLUDES_PS[@]}")" ]; then
    echo "❌ El árbol de trabajo tiene cambios sin commit:"
    git status --short -- . "${EXCLUDES_PS[@]}" | head -10 | sed 's/^/   /'
    echo "   Haz commit o stash antes de ejecutar, para que la auditoría de alcance sea confiable."
    echo "   (.pi/project.env, .pi/stack-profile.md y .pi/agents/ deben estar versionados.)"
    exit 1
  fi

  log_decision "$ISSUE_ID" "Ejecución iniciada (plan verificado, árbol limpio)"
  echo "======================================================"
  echo "🚀 Ejecutor: aplicando cambios aprobados ($ISSUE_ID)"
  echo "======================================================"

  if [ "$EXEC_MANUAL" != "1" ] && resolve_agent executor >/dev/null; then
    EXEC_OUT="$HANDOFF_DIR/${ISSUE_ID}-exec.md"
    PRE_ENV=$(guard_fingerprint)
    run_phase executor "Apply the approved plan stored at: $PLAN_FILE
Read it first. Apply ONLY the changes listed under each Target. Do not touch any other file. Do not refactor surrounding code." \
      "$EXEC_OUT" "$EXECUTOR_THINKING" "$EXECUTOR_MODEL" || exit 1

    if [ "$PRE_ENV" != "$(guard_fingerprint)" ]; then
      echo "🚨 ALERTA: cambiaron archivos protegidos durante la ejecución (.env*, .pi/project.env,"
      echo "   .pi/stack-profile.md o .pi/agents/). Revísalos antes de continuar."
      log_decision "$ISSUE_ID" "ALERTA: archivos protegidos modificados durante la ejecución"
      exit 1
    fi

    EXEC_V=$(tr -d '\r' < "$EXEC_OUT" | sed 's/[[:space:]]*$//' | grep -xE 'Execution: (COMPLETE|HALTED)' | sort -u)
    if [ "$(printf '%s\n' "$EXEC_V" | grep -c .)" -ne 1 ]; then
      echo "⚠️  El reporte del Ejecutor no contiene un veredicto único y válido. Revisa $EXEC_OUT y 'git diff'."
      log_decision "$ISSUE_ID" "Ejecutor: veredicto inválido"
      exit 3
    fi
    if [ "$EXEC_V" = "Execution: HALTED" ]; then
      echo "🛑 El Ejecutor se detuvo (HALT). Puede haber aplicado Targets parcialmente."
      echo "   Revisa $EXEC_OUT y 'git diff'; corrige o regenera el plan, o revierte con git."
      log_decision "$ISSUE_ID" "Ejecutor: HALTED"
      exit 2
    fi
    log_decision "$ISSUE_ID" "Ejecutor: COMPLETE"
    echo "✅ El Ejecutor terminó. Log: $EXEC_OUT"
    git diff --stat -- . "${EXCLUDES_PS[@]}"
    echo "   Siguiente paso: $0 --qa $ISSUE_ID"
  else
    echo "ℹ️  Ejecución manual (--manual, o no hay executor.md en la cadena de búsqueda):"
    echo "   1. Ejecuta: pi"
    echo "   2. Carga el plan: /pickup $PLAN_FILE"
    echo "   3. Ordena: 'Aplica los cambios exactos de este documento sin tocar archivos fuera de Target.'"
    echo "   Al terminar: $0 --qa $ISSUE_ID"
  fi
  exit 0
fi

# -----------------------------------------------------------------------------
# RUTA: --qa (auditoría de alcance + QA con guardarraíl de integridad)
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--qa" ]; then
  need_id "${2:-}"
  ISSUE_ID="$2"
  PLAN_FILE="$HANDOFF_DIR/${ISSUE_ID}-plan.md"
  QA_OUT="$HANDOFF_DIR/${ISSUE_ID}-qa.md"
  for _f in "${@:3}"; do
    case "$_f" in
      --allow-bash) QA_ALLOW_BASH=1 ;;
      *) echo "❌ Opción desconocida para --qa: $_f"; exit 1 ;;
    esac
  done
  if [ ! -f "$PLAN_FILE" ]; then echo "❌ No existe el plan: $PLAN_FILE"; exit 1; fi

  verify_plan_seal "$PLAN_FILE" || exit 1

  CHANGED=$(changed_files)
  if [ -z "$CHANGED" ]; then
    echo "❌ No hay cambios en el árbol de trabajo: no hay nada que auditar."
    echo "   ¿Se aplicó el plan? Revisa: git status"
    exit 1
  fi

  # Auditoría de alcance: cambios vs. Target del plan
  TARGETS=$(plan_targets "$PLAN_FILE")
  OUT_OF_SCOPE=$(comm -23 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$TARGETS"))
  UNAPPLIED=$(comm -13 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$TARGETS") | grep -v '^$')

  if [ -n "$UNAPPLIED" ]; then
    echo "⚠️  Targets del plan sin cambios (¿no se aplicaron?):"
    printf '%s\n' "$UNAPPLIED" | sed 's/^/   - /'
  fi
  if [ -n "$OUT_OF_SCOPE" ]; then
    echo "🚨 Archivos modificados FUERA de los Target del plan:"
    printf '%s\n' "$OUT_OF_SCOPE" | sed 's/^/   - /'
    log_decision "$ISSUE_ID" "Alcance: archivos fuera de Target: $(printf '%s' "$OUT_OF_SCOPE" | tr '\n' ' ')"
    if ! confirm "¿Continuar con QA de todos modos?"; then
      echo "🛑 QA cancelado. Revisa con: git status / git diff"
      exit 1
    fi
  fi

  # Guardarraíl de borrados masivos (p. ej. reescritura de un archivo entero con `write`)
  MAX_DELETED_LINES="${MAX_DELETED_LINES:-40}"
  HEAVY=$(git diff HEAD --numstat -- . "${EXCLUDES_PS[@]}" | awk -F'\t' -v max="$MAX_DELETED_LINES" '$2 ~ /^[0-9]+$/ && $2+0 > max {print $3 " (-" $2 " líneas)"}')
  if [ -n "$HEAVY" ]; then
    echo "🚨 Borrados grandes (más de $MAX_DELETED_LINES líneas eliminadas por archivo):"
    printf '%s\n' "$HEAVY" | sed 's/^/   - /'
    log_decision "$ISSUE_ID" "Borrados grandes: $(printf '%s' "$HEAVY" | tr '\n' ' ')"
    if ! confirm "¿Es lo esperado según el plan? ¿Continuar con QA?"; then
      echo "🛑 QA cancelado. Revisa con: git diff HEAD --stat"
      exit 1
    fi
  fi

  echo "⏳ Fase QA: validando cambios..."

  # Copia de referencia previa a QA: staged + unstaged (HEAD); los archivos nuevos van en un .tgz
  git diff HEAD -- . "${EXCLUDES_PS[@]}" > "$HANDOFF_DIR/${ISSUE_ID}-pre-qa.patch"
  if [ -n "$(changed_untracked)" ]; then
    changed_untracked | tar czf "$HANDOFF_DIR/${ISSUE_ID}-pre-qa-untracked.tgz" -T - 2>/dev/null
  fi

  # Diff y status se precalculan aquí para que QA pueda leerlos aunque no tenga bash
  git diff HEAD -- . "${EXCLUDES_PS[@]}" > "$HANDOFF_DIR/${ISSUE_ID}-changes.diff"
  git status --short -- . "${EXCLUDES_PS[@]}" > "$HANDOFF_DIR/${ISSUE_ID}-status.txt"

  if [ "${QA_ALLOW_BASH:-0}" = "1" ]; then
    QA_MODE_NOTE="Bash IS enabled for this run: you may run the tests your instructions allow, but only after passing the database safety check."
  else
    QA_MODE_NOTE="Bash is NOT available in this run: do not try to run tests. Give the human the exact commands to run."
  fi
  PRE_QA=$(tree_snapshot)
  PRE_GUARD=$(guard_fingerprint)

  run_phase qa "Audit the executed changes against the approved plan stored at: $PLAN_FILE
Read the plan first. The executed changes are precomputed: read $HANDOFF_DIR/${ISSUE_ID}-changes.diff (tracked changes) and $HANDOFF_DIR/${ISSUE_ID}-status.txt (git status; new untracked files appear only there, so read them with your read tool).
$QA_MODE_NOTE
Your final line must be exactly one verdict line." \
    "$QA_OUT" "$QA_THINKING" "$QA_MODEL"
  QA_RC=$?

  # QA no debe mutar código. Se compara el CONTENIDO; NO se revierte nada automáticamente.
  if [ "$PRE_QA" != "$(tree_snapshot)" ] || [ "$PRE_GUARD" != "$(guard_fingerprint)" ]; then
    echo "🚨 ALERTA: el agente QA modificó archivos durante su evaluación."
    echo "   NO se revirtió nada automáticamente (podría descartar el trabajo del Ejecutor)."
    echo "   Copia de referencia previa a QA (cambios trackeados): $HANDOFF_DIR/${ISSUE_ID}-pre-qa.patch"
    echo "   Revisa: git status / git diff"
    log_decision "$ISSUE_ID" "ALERTA: QA modificó el árbol de trabajo"
    exit 1
  fi
  if [ $QA_RC -ne 0 ]; then exit 1; fi

  # Veredicto: líneas completas "Resultado: X" en cualquier parte del reporte (tolera
  # ``` o texto de cortesía al final). Debe haber EXACTAMENTE un veredicto distinto;
  # si no hay ninguno o hay contradictorios, se asume MANUAL_REQUIRED (falla seguro).
  VERDICTS=$(tr -d '\r' < "$QA_OUT" | sed 's/[[:space:]]*$//' | grep -xE 'Resultado: (PASS|FAIL|MANUAL_REQUIRED)' | sort -u)
  if [ "$(printf '%s\n' "$VERDICTS" | grep -c .)" -eq 1 ]; then
    VERDICT="${VERDICTS#Resultado: }"
  else
    VERDICT="MANUAL_REQUIRED"
    echo "⚠️  El reporte no contiene un veredicto único y válido; se trata como MANUAL_REQUIRED."
  fi

  log_decision "$ISSUE_ID" "QA: $VERDICT"
  echo ""
  echo "📊 Veredicto QA: $VERDICT"
  echo "📄 Reporte: $QA_OUT"
  case "$VERDICT" in
    PASS)
      echo "   Si el reporte incluye protocolo manual (sección 4), ejecútalo antes de commitear."
      echo "   Luego: formateo (pint), revisión del diff y commit. Sugerencia (revísala antes de ejecutarla):"
      printf '   git add --'
      changed_files | while IFS= read -r f; do printf ' %q' "$f"; done
      printf '\n   git commit -m "Fix (%s): <resumen breve>"\n' "$ISSUE_ID"
      exit 0 ;;
    FAIL)
      echo "   Hay fallos: revisa el reporte y decide si vuelves a ejecutar o ajustas el plan."
      exit 4 ;;
    *)
      echo "   Requiere verificación manual: sigue los comandos/protocolo del reporte."
      exit 5 ;;
  esac
fi

# -----------------------------------------------------------------------------
# Flujo normal: Fase 1 (Analista con triage) -> Gate 1 -> Fase 2 (Arquitecto)
# -----------------------------------------------------------------------------
case "${1:-}" in
  --*) echo "❌ Opción desconocida: $1"; usage; exit 1 ;;
  "")  echo "Error: Debes proporcionar la descripción del Issue."; usage; exit 1 ;;
esac

ISSUE_TEXT="$1"
ISSUE_ID="${2:-$(date +%Y%m%d-%H%M%S)}"
need_id "$ISSUE_ID"
ANALYST_OUT="$HANDOFF_DIR/${ISSUE_ID}-analyst.md"

echo "======================================================"
echo "🚀 Ciclo de Trabajo Quirúrgico — $ISSUE_ID"
echo "======================================================"
echo "Issue: $ISSUE_TEXT"
if [ -z "$PP_EXT" ]; then
  echo "⚠️  protected-paths NO activo (falta la extensión o $PROTECTED_PATHS_CONFIG):"
  echo "    los agentes podrían leer .env y credenciales."
fi
echo "------------------------------------------------------"

echo "⏳ Fase 1: Analista (diagnóstico y triage)..."
run_phase analyst "Diagnose this issue. Locate the relevant files with your tools before diagnosing.

ISSUE:
$ISSUE_TEXT" "$ANALYST_OUT" "$ANALYST_THINKING" "$ANALYST_MODEL" || exit 1

if grep -qE "$RE_HALT" "$ANALYST_OUT"; then
  echo "🛑 El Analista no pudo ubicar los archivos. Se detiene aquí (el Arquitecto no se lanzó)."
  echo "   Revisa $ANALYST_OUT, corrige las rutas y vuelve a correr."
  exit 2
fi
if ! grep -q "Diagnosed, pending plan" "$ANALYST_OUT"; then
  echo "⚠️  La salida del Analista no sigue la plantilla esperada. Revisa $ANALYST_OUT."
  exit 3
fi

# --- GATE 1: triage. Solo [BUG_DIRECTO] exacto pasa sin preguntar. -----------
TRIAGE_STATUS=$(grep -m1 -E '^\* \*\*Triage:\*\* \[(BUG_DIRECTO|INFORME)\][[:space:]]*$' "$ANALYST_OUT" | grep -oE 'BUG_DIRECTO|INFORME' || true)
log_decision "$ISSUE_ID" "Triage: ${TRIAGE_STATUS:-SIN CLASIFICAR}"

if [ "$TRIAGE_STATUS" != "BUG_DIRECTO" ]; then
  echo "------------------------------------------------------"
  echo "⚠️  Triage: ${TRIAGE_STATUS:-SIN CLASIFICAR}. Requiere decisión humana."
  echo "📄 Lee el diagnóstico y el protocolo de validación en: $ANALYST_OUT"
  if ! confirm "🚧 GATE 1: ¿Generar el plan con el Arquitecto de todos modos?"; then
    log_decision "$ISSUE_ID" "Gate 1: cadena detenida por el usuario"
    echo "🛑 Cadena detenida en Gate 1. Caso pausado/escalado."
    echo "   Para retomar la fase del Arquitecto: $0 --plan $ISSUE_ID"
    exit 0
  fi
  log_decision "$ISSUE_ID" "Gate 1: usuario autorizó continuar al Arquitecto"
fi

run_architect "$ISSUE_ID"