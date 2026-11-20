/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * The sleep state S3 for the AMD BC-250. The board's DSDT names no \_S3, so the kernel offers only
 * s2idle, from which this board does not come back. With this table the kernel offers S3 ("deep" in
 * /sys/power/mem_sleep). The values are the sleep type written to the PM1 control register.
 *
 * acpi/SSDT-S3.aml is this, compiled: iasl -tc SSDT-S3.dsl
 */
DefinitionBlock ("", "SSDT", 2, "BC250 ", "S3SLEEP ", 0x00000001)
{
    Name (\_S3, Package (0x04)
    {
        0x03,
        Zero,
        Zero,
        Zero
    })
}
