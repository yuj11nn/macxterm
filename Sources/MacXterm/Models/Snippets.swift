import Foundation
import Observation

/// Команда-подсказка: встроенная или своя.
struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var command: String
    var category: String
    var isCustom = false

    /// Курсор встаёт на место `‸` (если есть), сам символ не отправляется.
    var cursorBack: Int {
        guard let r = command.range(of: "‸") else { return 0 }
        return command[r.upperBound...].count
    }
    var plainCommand: String { command.replacingOccurrences(of: "‸", with: "") }
}

/// Встроенная библиотека + свои команды + частота использования (UserDefaults).
@MainActor @Observable
final class SnippetStore {
    static let customCategory = "Мои команды"
    private static let customKey = "customSnippets"
    private static let usageKey = "snippetUsage"

    private(set) var custom: [Snippet] = []
    private(set) var usage: [String: Int] = [:]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.customKey), let v = try? JSONDecoder().decode([Snippet].self, from: data) { custom = v }
        usage = (d.dictionary(forKey: Self.usageKey) as? [String: Int]) ?? [:]
    }

    var all: [Snippet] { custom + Self.builtin }

    /// Самые частые (минимум 2 использования), до 6 штук.
    var frequent: [Snippet] {
        all.filter { (usage[$0.id] ?? 0) >= 2 }
            .sorted { (usage[$0.id] ?? 0) > (usage[$1.id] ?? 0) }
            .prefix(6).map { $0 }
    }

    func markUsed(_ s: Snippet) {
        usage[s.id, default: 0] += 1
        UserDefaults.standard.set(usage, forKey: Self.usageKey)
    }

    func save(_ s: Snippet) {
        var s = s
        s.isCustom = true
        s.category = Self.customCategory
        if let i = custom.firstIndex(where: { $0.id == s.id }) { custom[i] = s } else { custom.insert(s, at: 0) }
        persist()
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        usage[id] = nil
        UserDefaults.standard.set(usage, forKey: Self.usageKey)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: Self.customKey) }
    }

    // MARK: - Встроенные

    private static func group(_ cat: String, _ items: [(String, String)]) -> [Snippet] {
        items.enumerated().map { i, it in Snippet(id: "b:\(cat):\(i)", title: it.0, command: it.1, category: cat) }
    }

    static let builtin: [Snippet] =
        group("Система", [
            ("Сводка: ОС, ядро, аптайм", "cat /etc/os-release | head -4; uname -r; uptime"),
            ("Память", "free -h"),
            ("Место на дисках", "df -h"),
            ("Кто залогинен", "w"),
            ("Последние входы", "last -n 20"),
            ("Монитор процессов", "htop || top"),
            ("Перезагрузить сервер", "sudo reboot"),
        ])
        + group("Процессы", [
            ("Топ по CPU", "ps aux --sort=-%cpu | head -15"),
            ("Топ по памяти", "ps aux --sort=-%mem | head -15"),
            ("Найти процесс", "pgrep -af ‸"),
            ("Убить по имени", "pkill -f ‸"),
            ("Дерево процессов", "pstree -p | less"),
        ])
        + group("Файлы", [
            ("Что занимает место здесь", "du -sh -- * .[!.]* 2>/dev/null | sort -h | tail -20"),
            ("Крупные файлы > 100 МБ", "find / -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null | sort -k5 -h | tail -20"),
            ("Найти файл по имени", "find . -iname '*‸*' 2>/dev/null"),
            ("Поиск текста в файлах", "grep -rn '‸' ."),
            ("Подробный листинг", "ls -lah"),
            ("Архивировать каталог", "tar czf archive.tar.gz ‸"),
            ("Распаковать .tar.gz", "tar xzf ‸"),
        ])
        + group("Сеть", [
            ("Открытые порты", "ss -tulpn"),
            ("IP-адреса", "ip -br a"),
            ("Внешний IP", "curl -s ifconfig.me; echo"),
            ("Соединения по количеству", "ss -tn state established | awk 'NR>1{print $4}' | sort | uniq -c | sort -rn | head"),
            ("Проверить порт", "nc -zv ‸ 443"),
            ("Заголовки ответа", "curl -sI https://‸"),
            ("Правила firewall", "sudo iptables -L -n -v --line-numbers 2>/dev/null || sudo ufw status verbose"),
        ])
        + group("Службы и логи", [
            ("Статус службы", "systemctl status ‸"),
            ("Перезапустить службу", "sudo systemctl restart ‸"),
            ("Упавшие службы", "systemctl --failed"),
            ("Лог службы (follow)", "journalctl -u ‸ -f"),
            ("Ошибки за час", "journalctl -p err --since '1 hour ago' --no-pager"),
            ("Системный лог (follow)", "journalctl -f"),
            ("Хвост файла лога", "tail -f /var/log/‸"),
        ])
        + group("Docker", [
            ("Контейнеры", "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"),
            ("Все контейнеры", "docker ps -a"),
            ("Нагрузка контейнеров", "docker stats --no-stream"),
            ("Логи контейнера", "docker logs -f --tail 100 ‸"),
            ("Шелл в контейнере", "docker exec -it ‸ sh"),
            ("Compose: перезапуск", "docker compose up -d --build"),
            ("Очистить мусор", "docker system prune"),
        ])
        + group("Пакеты", [
            ("apt: обновить всё", "sudo apt update && sudo apt upgrade"),
            ("apt: установить", "sudo apt install ‸"),
            ("dnf: обновить всё", "sudo dnf upgrade"),
            ("Установленные пакеты (apt)", "apt list --installed 2>/dev/null | grep ‸"),
        ])
}
