// Tiara host-side character device.
//
// Wraps the AXI-Lite app-control region of the Corundum mqnic into a
// /dev/tiaraN character device that userspace mmaps.  The mqnic driver
// already exposes the BAR through its own /dev nodes; this driver just
// carves out the app-control window so a Tiara client library can poke
// it with PIO.
//
// Build:  make -C host
// Load:   sudo insmod tiara_drv.ko
// Use:    open("/dev/tiara0", O_RDWR); mmap(...);

#include <linux/cdev.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#define DRV_NAME       "tiara"
#define TIARA_BAR_OFF  0x40000     /* Corundum app-ctrl region offset */
#define TIARA_BAR_SIZE 0x4000      /* 16 KB window */

struct tiara_dev {
    struct pci_dev *pdev;
    void __iomem    *base;
    resource_size_t  bar_phys;
    resource_size_t  bar_len;
    struct cdev      cdev;
    dev_t            devt;
};

static struct class *tiara_class;
static dev_t         tiara_first;
static int           tiara_minor_count = 8;
static struct tiara_dev *tiara_devs[8];
static int           tiara_n_devs = 0;

/* ------------------------------------------------------------------ */

static int tiara_open(struct inode *ino, struct file *f) {
    struct tiara_dev *d = container_of(ino->i_cdev, struct tiara_dev, cdev);
    f->private_data = d;
    return 0;
}

static int tiara_mmap(struct file *f, struct vm_area_struct *vma) {
    struct tiara_dev *d = f->private_data;
    unsigned long len = vma->vm_end - vma->vm_start;
    if (len > TIARA_BAR_SIZE) return -EINVAL;
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
    return io_remap_pfn_range(vma, vma->vm_start,
                              (d->bar_phys + TIARA_BAR_OFF) >> PAGE_SHIFT,
                              len, vma->vm_page_prot);
}

static const struct file_operations tiara_fops = {
    .owner = THIS_MODULE,
    .open  = tiara_open,
    .mmap  = tiara_mmap,
};

/* ------------------------------------------------------------------ */
/* Probe: bind to the Corundum-augmented mqnic on PCI vendor 0x1234,
   device 0x1001 (the standard Corundum dev id; matches what
   `lspci -n` shows after `make program`).                              */

static int tiara_probe(struct pci_dev *pdev, const struct pci_device_id *id) {
    struct tiara_dev *d;
    int rc;

    if (tiara_n_devs >= tiara_minor_count) return -ENOSPC;

    d = kzalloc(sizeof(*d), GFP_KERNEL);
    if (!d) return -ENOMEM;
    d->pdev = pdev;

    rc = pci_enable_device(pdev);
    if (rc) goto err;
    rc = pci_request_region(pdev, 0, DRV_NAME);
    if (rc) goto err_disable;
    d->bar_phys = pci_resource_start(pdev, 0);
    d->bar_len  = pci_resource_len(pdev, 0);
    d->base     = ioremap(d->bar_phys, d->bar_len);
    if (!d->base) { rc = -ENOMEM; goto err_region; }

    d->devt = MKDEV(MAJOR(tiara_first), tiara_n_devs);
    cdev_init(&d->cdev, &tiara_fops);
    rc = cdev_add(&d->cdev, d->devt, 1);
    if (rc) goto err_unmap;
    device_create(tiara_class, &pdev->dev, d->devt, NULL,
                  DRV_NAME "%d", tiara_n_devs);

    tiara_devs[tiara_n_devs++] = d;
    pci_set_drvdata(pdev, d);
    dev_info(&pdev->dev, "tiara: bound, BAR0 phys=%pa len=%llu\n",
             &d->bar_phys, (unsigned long long)d->bar_len);
    return 0;

err_unmap:    iounmap(d->base);
err_region:   pci_release_region(pdev, 0);
err_disable:  pci_disable_device(pdev);
err:          kfree(d);
              return rc;
}

static void tiara_remove(struct pci_dev *pdev) {
    struct tiara_dev *d = pci_get_drvdata(pdev);
    if (!d) return;
    device_destroy(tiara_class, d->devt);
    cdev_del(&d->cdev);
    iounmap(d->base);
    pci_release_region(pdev, 0);
    pci_disable_device(pdev);
    kfree(d);
}

static const struct pci_device_id tiara_ids[] = {
    { PCI_DEVICE(0x1234, 0x1001) },   /* Corundum default */
    { 0, },
};
MODULE_DEVICE_TABLE(pci, tiara_ids);

static struct pci_driver tiara_pci_driver = {
    .name     = DRV_NAME,
    .id_table = tiara_ids,
    .probe    = tiara_probe,
    .remove   = tiara_remove,
};

/* ------------------------------------------------------------------ */

static int __init tiara_init(void) {
    int rc;
    rc = alloc_chrdev_region(&tiara_first, 0, tiara_minor_count, DRV_NAME);
    if (rc) return rc;
    tiara_class = class_create(THIS_MODULE, DRV_NAME);
    if (IS_ERR(tiara_class)) {
        unregister_chrdev_region(tiara_first, tiara_minor_count);
        return PTR_ERR(tiara_class);
    }
    return pci_register_driver(&tiara_pci_driver);
}

static void __exit tiara_exit(void) {
    pci_unregister_driver(&tiara_pci_driver);
    class_destroy(tiara_class);
    unregister_chrdev_region(tiara_first, tiara_minor_count);
}

module_init(tiara_init);
module_exit(tiara_exit);

MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("Tiara host-side character device");
MODULE_AUTHOR("Tiara contributors");
