import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Super Admin only: who works here, what they are allowed to do, and how
/// much discount they may hand out.
class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  List<Employee> _staff = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await context.read<AppState>().api.employees();
      setState(() => _staff = raw.map(Employee.new).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(children: [
          SectionCard(
            title: 'How to add a new employee',
            actions: [
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('1.  In Supabase: Authentication → Users → “Add user”. Type their email and a '
                  'password, and tick “Auto Confirm User”.'),
              SizedBox(height: 8),
              Text('2.  That person now appears in the list below — set their role, discount limit '
                  'and salary here.'),
              SizedBox(height: 8),
              Text('3.  They sign in on any of the 4 PCs with that email and password.'),
              SizedBox(height: 12),
              Text(
                'Roles:  Manager — can do everything except staff, store settings and discount rules.   '
                'Cashier — sells, and can only discount up to their own limit.',
                style: TextStyle(fontSize: 12.5),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Staff (${_staff.length})',
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              child: DataTable(
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Name')),
                  DataColumn(label: Text('Login / username')),
                  DataColumn(label: Text('Role')),
                  DataColumn(label: Text('Discount limit'), numeric: true),
                  DataColumn(label: Text('Phone')),
                  DataColumn(label: Text('Salary'), numeric: true),
                  DataColumn(label: Text('Last seen')),
                  DataColumn(label: Text('Status')),
                ],
                rows: [
                  for (final e in _staff)
                    DataRow(
                      onSelectChanged: (_) => _edit(state, e),
                      cells: [
                        DataCell(Text(e.fullName, style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(Text('${e.email}\n${e.username}')),
                        DataCell(StatusPill(
                          text: e.role.replaceAll('_', ' '),
                          color: e.role == 'super_admin'
                              ? AppColors.danger
                              : (e.role == 'cashier' ? AppColors.info : AppColors.good),
                        )),
                        DataCell(Text('${num2(e.maxDiscountPercent)}%')),
                        DataCell(Text(e.phone.isEmpty ? '—' : e.phone)),
                        DataCell(Text(e.salary.isEmpty ? '—' : num2(e.salary))),
                        DataCell(Text(agoLabel(e.lastLogin))),
                        DataCell(StatusPill(
                          text: e.isActive ? 'on duty' : 'disabled',
                          color: e.isActive ? AppColors.good : AppColors.danger,
                        )),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _edit(AppState state, Employee e) async {
    final name = TextEditingController(text: e.fullName);
    final username = TextEditingController(text: e.username);
    final phone = TextEditingController(text: e.phone);
    final salary = TextEditingController(text: e.salary);
    final discount = TextEditingController(text: num2(e.maxDiscountPercent));
    final cnic = TextEditingController(text: e.cnic);
    final address = TextEditingController(text: e.address);
    final designation = TextEditingController(text: e.designation);
    final joined = TextEditingController();
    String role = e.role;
    bool active = e.isActive;

    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(e.fullName.isEmpty ? 'Staff member' : e.fullName),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                        controller: name, decoration: const InputDecoration(labelText: 'Full name')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                        controller: username,
                        decoration: const InputDecoration(labelText: 'Username (till login label)')),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: designation,
                      decoration: const InputDecoration(
                          labelText: 'Designation', hintText: 'Cashier / Store keeper / Guard'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: cnic,
                      decoration: const InputDecoration(labelText: 'CNIC', hintText: '42101-1234567-1'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: address,
                      decoration: const InputDecoration(labelText: 'Home address'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: joined,
                      decoration: const InputDecoration(
                          labelText: 'Joined on (optional)', hintText: 'yyyy-mm-dd'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: role,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: const [
                        DropdownMenuItem(value: 'cashier', child: Text('Cashier — sells only')),
                        DropdownMenuItem(value: 'manager', child: Text('Manager — full store control')),
                        DropdownMenuItem(value: 'admin', child: Text('Admin — manager + discounts')),
                        DropdownMenuItem(value: 'super_admin', child: Text('Super Admin — everything')),
                      ],
                      onChanged: (v) => setLocal(() => role = v ?? role),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: discount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Max discount %',
                        helperText: 'The server refuses anything above this',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                        controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: salary,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Monthly salary'),
                    ),
                  ),
                ]),
                SwitchListTile(
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                  title: const Text('Can sign in'),
                  subtitle: const Text('Turn off for someone who has left — their history stays'),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                // the two changes that can lock the shop or hand over every power get a check first
                final promoting = role == 'super_admin' && e.role != 'super_admin';
                final deactivating = !active && e.isActive;
                if (promoting || deactivating) {
                  final sure = await confirm(
                    c,
                    title: promoting ? 'Make ${e.fullName} a Super Admin?' : 'Deactivate ${e.fullName}?',
                    message: promoting
                        ? 'A Super Admin can change every setting, approve anything and set anyone\'s PIN.'
                        : 'They will be signed out of every till and cannot sign in until reactivated.',
                    okLabel: promoting ? 'Yes, make Super Admin' : 'Deactivate',
                  );
                  if (!sure || !c.mounted) return;
                }
                final discountValue = parseAmount(discount.text);
                if (discountValue == null || discountValue < 0 || discountValue > 100) {
                  showMessage(c, 'Maximum discount must be a number from 0 to 100', error: true);
                  return;
                }
                try {
                  await state.api.saveEmployee({
                    'id': e.id,
                    'full_name': name.text.trim(),
                    'username': username.text.trim(),
                    'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
                    'salary': salary.text.trim().isEmpty ? null : parseAmount(salary.text),
                    'max_discount_percent': discountValue,
                    'role': role,
                    'is_active': active,
                    'cnic': cnic.text.trim().isEmpty ? null : cnic.text.trim(),
                    'address': address.text.trim().isEmpty ? null : address.text.trim(),
                    'designation': designation.text.trim().isEmpty ? null : designation.text.trim(),
                  });
                  if (c.mounted) Navigator.pop(c, true);
                } catch (err) {
                  if (c.mounted) showError(c, err);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _load();
      if (mounted) showMessage(context, 'Staff record updated');
    }
  }
}
