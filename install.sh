#!/bin/sh
set -eu
export LC_ALL=C

fail() { printf 'Erro: %s\n' "$*" >&2; exit 1; }
valid_name() {
    case "$1" in
        ''|*[!a-z0-9-]*|-*|*-|*--*) fail "Nome de skill inválido: $1" ;;
    esac
}
check_path() {
    if [ -L "$1" ] || { [ -e "$1" ] && ! test "$2" "$1"; }; then
        fail "Caminho incompatível ou link simbólico: $1"
    fi
}

main() {
[ "$#" -eq 0 ] || fail 'Uso: sh install.sh'
if ! ( : 3<>/dev/tty ) 2>/dev/null; then
    fail 'É necessário um terminal interativo para responder às perguntas.'
fi
exec 3<>/dev/tty
printf 'Diretório do projeto de destino: ' >&3
IFS= read -r destination <&3 || fail 'Não foi possível ler o diretório de destino.'
[ -n "$destination" ] || fail 'O diretório de destino não pode estar vazio.'
project=$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null) ||
    fail 'O destino deve ser um diretório de um projeto Git.'
printf '%s\n' 'Responder n remove as skills gerenciadas que continuam experimentais.' >&3
printf 'Incluir skills experimentais? [s/n]: ' >&3
IFS= read -r answer <&3 || fail 'Não foi possível ler a resposta sobre skills experimentais.'
case "$answer" in
    s|S) experimental=true ;;
    n|N) experimental=false ;;
    *) fail 'Responda s ou n para as skills experimentais.' ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/certi-ai-assets.XXXXXX")
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM

git init -q "$work/assets"
repo_url=${CERTI_AI_ASSETS_REPO_URL:-git@ssh.bitbucket.org:certi_repos/certi-ai-assets.git}
git -C "$work/assets" fetch -q --depth=1 --no-tags -- "$repo_url" HEAD ||
    fail 'Não foi possível buscar a branch padrão remota.'
revision=$(git -C "$work/assets" rev-parse --verify FETCH_HEAD)
git -C "$work/assets" -c core.autocrlf=false checkout -q --detach "$revision"
check_path "$work/assets/baselines/common/AGENTS.md" -f
[ -f "$work/assets/baselines/common/AGENTS.md" ] || fail 'Baseline comum ausente na origem.'

skills="$project/.agents/skills"
record="$project/.agents/certi-ai-assets.manifest"
agents="$project/AGENTS.md"
check_path "$project/.agents" -d
check_path "$skills" -d
check_path "$record" -f
check_path "$agents" -f
: > "$work/previous"
if [ -f "$record" ]; then
    awk '{ sub(/\r$/, ""); print }' "$record" > "$work/previous"
fi
while IFS= read -r name; do
    valid_name "$name"
    check_path "$skills/$name" -d
done < "$work/previous"

# Calcular limites em bytes permite preservar também CRLF e a ausência de LF final.
prefix=0 suffix=0 managed=0
if [ -f "$agents" ]; then
    LC_ALL=C awk '
        BEGIN { offset = 0; state = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (NR == 1 && line ~ /^# /) title = length($0) + 1
            if (index(line, "<!-- certi-ai-assets: baselines/")) exit 1
            if (index(line, "<!-- certi-ai-assets:baseline:")) {
                if (line == "<!-- certi-ai-assets:baseline:begin -->" && state == 0) {
                    start = offset
                    state = 1
                } else if (line == "<!-- certi-ai-assets:baseline:end -->" && state == 1) {
                    finish = offset + length($0) + 1
                    state = 2
                } else exit 1
            }
            offset += length($0) + 1
        }
        END {
            if (state == 1) exit 1
            if (state == 2) print start, finish, 1
            else print title + 0, title + 0, 0
        }
    ' "$agents" > "$work/bounds" ||
        fail 'Marcadores de baseline inválidos ou legados. Corrija os limites antes de instalar.'
    read -r prefix suffix managed < "$work/bounds"
fi
{
    if [ "$prefix" -gt 0 ]; then
        dd if="$agents" bs=1 count="$prefix" 2>/dev/null
        [ "$managed" -eq 1 ] || printf '\n'
    fi
    printf '%s\n' '<!-- certi-ai-assets:baseline:begin -->'
    cat "$work/assets/baselines/common/AGENTS.md"
    printf '\n%s\n' '<!-- certi-ai-assets:baseline:end -->'
    if [ -f "$agents" ]; then
        [ "$managed" -eq 1 ] || printf '\n'
        dd if="$agents" bs=1 skip="$suffix" 2>/dev/null
    fi
} > "$work/AGENTS.md"
mkdir "$work/skills"
: > "$work/selected"
: > "$work/catalog"
for tier in stable experimental; do
    for skill in "$work/assets/skills/$tier/"*; do
        [ -e "$skill" ] || [ -L "$skill" ] || continue
        check_path "$skill" -d
        check_path "$skill/SKILL.md" -f
        name=$(basename "$skill")
        valid_name "$name"
        awk -v name="$name" '
            { sub(/\r$/, "") }
            NR == 1 { if ($0 != "---") exit 1; next }
            $0 == "---" { closed = 1; exit }
            /^name:/ {
                value = $0
                sub(/^name:[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                if (value != name && value != "\"" name "\"" &&
                    value != sprintf("%c%s%c", 39, name, 39)) exit 1
                found++
            }
            END { if (!closed || found != 1) exit 1 }
        ' "$skill/SKILL.md" || fail "Frontmatter name deve coincidir com o diretório: $name"
        if grep -Fxq "$name" "$work/catalog"; then
            fail "Nome de skill repetido entre estáveis e experimentais: $name"
        fi
        printf '%s\n' "$name" >> "$work/catalog"
        [ "$tier" = stable ] || "$experimental" || continue
        cp -R "$skill" "$work/skills/$name"
        printf '%s\n' "$name" >> "$work/selected"
    done
done
LC_ALL=C sort "$work/selected" > "$work/manifest"

while IFS= read -r name; do
    check_path "$skills/$name" -d
    if [ -e "$skills/$name" ] || [ -L "$skills/$name" ]; then
        if ! grep -Fxq "$name" "$work/previous"; then
            fail "Conflito com skill não gerenciada: $name. Mova ou remova a pasta e tente novamente."
        fi
    fi
done < "$work/manifest"

mkdir -p "$skills"
while IFS= read -r name; do
    rm -rf "$skills/$name"
done < "$work/previous"
while IFS= read -r name; do
    cp -R "$work/skills/$name" "$skills/$name"
done < "$work/manifest"
cp "$work/AGENTS.md" "$project/AGENTS.md"
cp "$work/manifest" "$record"
printf 'Baseline e skills instalados em %s\n' "$project"
}

main "$@" </dev/null
