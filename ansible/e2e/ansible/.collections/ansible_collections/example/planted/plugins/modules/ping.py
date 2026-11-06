# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A module that resolves only through ansible.cfg's collections_path."""

from ansible.module_utils.basic import AnsibleModule

AnsibleModule(argument_spec={}).exit_json(changed=False)
